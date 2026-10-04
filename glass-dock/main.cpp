// Glass Dock: the window around Dock.qml. QML draws everything; this only gives the process its
// own name (KWin names a layer-shell window after its executable), hands the settings over, and
// does the things QML has no API for: asking KWin to blur what is behind the dock, talking to
// media players (MPRIS) and to Pear Remote, and listening to the sound for the equaliser.
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusConnectionInterface>
#include <QDBusInterface>
#include <QDBusMessage>
#include <QDBusReply>
#include <QFile>
#include <QGuiApplication>
#include <QJsonDocument>
#include <QJsonObject>
#include <QPainterPath>
#include <QProcess>
#include <QTimer>
#include <array>
#include <cmath>
#include <complex>
#include <vector>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickWindow>
#include <QRegularExpression>
#include <QStandardPaths>
#include <KWindowEffects>

class Glass : public QObject {
    Q_OBJECT
public:
    // The dock's shape: rounded rectangles (the pill, and the panel under it when one is open).
    // KWin blurs behind them, and only they take the mouse: the rest of the window is click-through.
    // bridge: the gap between pill and panel, so the mouse can cross it without leaving the dock.
    Q_INVOKABLE void shape(QQuickWindow *w, const QVariantList &rects, qreal radius, const QRectF &bridge) {
        if (!w) return;
        QRegion region;
        for (const QVariant &v : rects) {
            QPainterPath p;
            p.addRoundedRect(v.toRectF(), radius, radius);
            region += QRegion(p.toFillPolygon().toPolygon());
        }
        if (region.isEmpty()) return;
        KWindowEffects::enableBlurBehind(w, true, region);
        w->setMask(region + bridge.toRect());
    }
};

class Media : public QObject {
    Q_OBJECT
    QString target;  // the player the dock is showing; kept while it is paused, so it can be resumed

    // KDE Connect and Plasma's browser integration mirror other players: not the real thing
    static bool real(const QString &service) {
        return service.startsWith("org.mpris.MediaPlayer2.") && !service.contains("kdeconnect")
            && !service.endsWith(".plasma-browser-integration");
    }
    static QVariant prop(const QString &service, const QString &name) {
        QDBusInterface i(service, "/org/mpris/MediaPlayer2", "org.freedesktop.DBus.Properties");
        i.setTimeout(300);
        QDBusReply<QVariant> r = i.call("Get", "org.mpris.MediaPlayer2.Player", name);
        return r.isValid() ? r.value() : QVariant();
    }
public:
    // title: what the dock shows as playing ("" when nothing is). Remembers which player that is,
    // and returns that player's state: "Playing", "Paused", "Stopped", or "" once it is gone.
    Q_INVOKABLE QString sync(const QString &title) {
        const QStringList names = QDBusConnection::sessionBus().interface()->registeredServiceNames().value();
        if (!title.isEmpty()) {
            QString found;
            for (const QString &n : names) {
                if (!real(n)) continue;
                if (prop(n, "PlaybackStatus").toString() != "Playing") continue;
                if (found.isEmpty()) found = n;
                const QVariantMap meta = qdbus_cast<QVariantMap>(prop(n, "Metadata"));
                if (meta.value("xesam:title").toString() == title) { found = n; break; }
            }
            if (!found.isEmpty()) target = found;
        }
        if (!target.isEmpty() && !names.contains(target)) { target.clear(); return {}; }
        if (target.isEmpty()) {
            // none remembered: settle on one that is idle and can be started, for the play button
            for (const QString &n : names) {
                if (!real(n) || !prop(n, "CanPlay").toBool()) continue;
                if (prop(n, "PlaybackStatus").toString() == "Playing") continue;
                target = n;
                break;
            }
        }
        if (target.isEmpty()) return {};
        return prop(target, "PlaybackStatus").toString();
    }
    // A YouTube video some player is playing: { id, title, author }, or {} if none. The now-playing
    // feed follows music only, so the dock looks for these itself. Remembers that player, like sync().
    Q_INVOKABLE QVariantMap video() {
        static const QRegularExpression yt(
            R"(^https?://(?:www\.|m\.)?(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|live/|embed/)|youtu\.be/)([\w-]{11}))");
        const QStringList names = QDBusConnection::sessionBus().interface()->registeredServiceNames().value();
        for (const QString &n : names) {
            if (!real(n) || prop(n, "PlaybackStatus").toString() != "Playing") continue;
            const QVariantMap meta = qdbus_cast<QVariantMap>(prop(n, "Metadata"));
            const auto m = yt.match(meta.value("xesam:url").toString());
            if (!m.hasMatch()) continue;
            target = n;
            return {{"id", m.captured(1)}, {"title", meta.value("xesam:title").toString()},
                    {"author", meta.value("xesam:artist").toStringList().join(", ")}};
        }
        return {};
    }
    // Pear Remote (pear-corner): held open while the pointer is on the dock's track, then released
    Q_INVOKABLE void remote(bool hold) {
        QDBusConnection::sessionBus().asyncCall(QDBusMessage::createMethodCall(
            "rip.cyb.PearCorner", "/", "rip.cyb.PearCorner", hold ? "Hold" : "Release"));
    }
    // "Play", "PlayPause", "Next" or "Previous", to the remembered player
    Q_INVOKABLE void cmd(const QString &method) {
        if (target.isEmpty()) return;
        QDBusConnection::sessionBus().asyncCall(QDBusMessage::createMethodCall(
            target, "/org/mpris/MediaPlayer2", "org.mpris.MediaPlayer2.Player", method));
    }
};

// The equaliser's ears: everything the default output plays (its monitor, read through parec),
// as BARS numbers 0..1 about 30 times a second, low notes first. Each is how loud that slice of
// the spectrum is against the loudest recent moment, so the volume setting doesn't matter.
class Spectrum : public QObject {
    Q_OBJECT
    static constexpr int RATE = 48000, WIN = 4096, HOP = 1600, BARS = 16;
    static constexpr double LOW = 45, HIGH = 15000;  // Hz
    QProcess rec;
    QByteArray raw;
    std::vector<float> buf = std::vector<float>(WIN, 0.f);
    std::array<double, BARS> bars{};
    double ref = 0;
    bool wanted = false, silent = true;

    static void fft(std::vector<std::complex<float>> &a) {
        const size_t n = a.size();
        for (size_t i = 1, j = 0; i < n; i++) {
            size_t bit = n >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(a[i], a[j]);
        }
        for (size_t len = 2; len <= n; len <<= 1) {
            const std::complex<float> w = std::polar(1.f, float(-2 * M_PI / len));
            for (size_t i = 0; i < n; i += len) {
                std::complex<float> x = 1;
                for (size_t k = 0; k < len / 2; k++, x *= w) {
                    const auto u = a[i + k], v = a[i + k + len / 2] * x;
                    a[i + k] = u + v;
                    a[i + k + len / 2] = u - v;
                }
            }
        }
    }
    void start() {
        if (!wanted || rec.state() != QProcess::NotRunning) return;
        raw.clear();
        rec.start("parec", {"-d", "@DEFAULT_MONITOR@", "--format=s16le", "--rate=48000", "--channels=1",
                            "--latency-msec=30", "--raw", "--client-name=glass-dock"});
    }
    void read() {
        raw += rec.readAllStandardOutput();
        const qsizetype hop = HOP * 2;
        qsizetype at = 0;
        // only the newest hop is worth an FFT if several piled up; the samples all go in the window
        for (; raw.size() - at >= hop; at += hop) {
            std::move(buf.begin() + HOP, buf.end(), buf.begin());
            const auto *s = reinterpret_cast<const qint16 *>(raw.constData() + at);
            for (int i = 0; i < HOP; i++) buf[WIN - HOP + i] = s[i] / 32768.f;
            if (raw.size() - at - hop < hop) hear();
        }
        raw.remove(0, at);
    }
    void hear() {
        double power = 0;
        for (int i = WIN - HOP; i < WIN; i++) power += buf[i] * buf[i];
        std::array<double, BARS> now{};
        if (std::sqrt(power / HOP) > 1e-4) {
            std::vector<std::complex<float>> a(WIN);
            for (int i = 0; i < WIN; i++) a[i] = buf[i] * float(0.5 - 0.5 * std::cos(2 * M_PI * i / (WIN - 1)));
            fft(a);
            double top = 0;
            for (int b = 0; b < BARS; b++) {
                const double f0 = LOW * std::pow(HIGH / LOW, double(b) / BARS), f1 = LOW * std::pow(HIGH / LOW, double(b + 1) / BARS);
                const int lo = std::max(1, int(f0 * WIN / RATE)), hi = std::max(lo + 1, int(f1 * WIN / RATE));
                double sum = 0;
                for (int k = lo; k < hi; k++) sum += std::norm(a[k]);
                // music thins out towards the top: lift it by 3 dB an octave so the high bars move too
                now[b] = std::sqrt(sum / (hi - lo)) * std::sqrt(std::sqrt(f0 * f1) / LOW);
                top = std::max(top, now[b]);
            }
            ref = std::max({top, ref * 0.997, 1e-3});          // the loudest bar of the last ten seconds or so
            for (double &v : now) v = std::clamp(1 + 20 * std::log10(std::max(v, 1e-9) / ref) / 36, 0., 1.);  // 36 dB tall
        }
        bool any = false;
        QVariantList out;
        for (int b = 0; b < BARS; b++) {
            bars[b] = std::max(now[b], bars[b] - 0.07);       // up at once, down in half a second
            any |= bars[b] > 0;
            out << bars[b];
        }
        if (any || !silent) emit heard(out);                   // silence: one row of zeros, then nothing
        silent = !any;
    }
public:
    Spectrum() {
        connect(&rec, &QProcess::readyReadStandardOutput, this, &Spectrum::read);
        // the sound server restarting ends the recording: pick it up again
        connect(&rec, &QProcess::finished, this, [this] { QTimer::singleShot(3000, this, &Spectrum::start); });
    }
    ~Spectrum() { wanted = false; rec.kill(); rec.waitForFinished(500); }
    // the dock listens only while the bars are on show
    Q_INVOKABLE void listen(bool on) {
        if (on == wanted) return;
        wanted = on;
        if (on) start();
        else rec.kill();
    }
signals:
    void heard(const QVariantList &levels);
};

int main(int argc, char **argv) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("glass-dock");
    const QString dir = argc > 1 ? argv[1] : DOCK_DIR;
    // settings: ~/.config/lavaglass/glass-dock.json, else config.json next to Dock.qml
    QFile f(QStandardPaths::locate(QStandardPaths::GenericConfigLocation, "lavaglass/glass-dock.json"));
    if (!f.exists()) f.setFileName(dir + "/config.json");
    QVariantMap cfg;
    if (f.open(QIODevice::ReadOnly)) cfg = QJsonDocument::fromJson(f.readAll()).object().toVariantMap();
    Glass glass;
    Media media;
    Spectrum spectrum;
    QQmlApplicationEngine engine;
    engine.rootContext()->setContextProperty("CFG", cfg);
    engine.rootContext()->setContextProperty("Glass", &glass);
    engine.rootContext()->setContextProperty("Media", &media);
    engine.rootContext()->setContextProperty("Spectrum", &spectrum);
    engine.load(QUrl::fromLocalFile(dir + "/Dock.qml"));
    if (engine.rootObjects().isEmpty()) return 1;
    return app.exec();
}

#include "main.moc"
