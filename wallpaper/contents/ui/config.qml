import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import "Moods.js" as Moods

Kirigami.FormLayout {
    id: root
    property alias cfg_Palette: palette.currentIndex
    property alias cfg_Speed: speed.value
    property alias cfg_Brightness: brightness.value
    property alias cfg_CycleHours: cycle.value
    property alias cfg_Fps: fps.value
    property alias cfg_PauseWhenCovered: pause.checked
    property alias cfg_FollowMusic: music.checked
    property alias cfg_Fusion: fuse.checked
    property alias cfg_FusionStyle: fusion.currentIndex
    property alias cfg_VideoColour: video.checked
    property string cfg_MusicUrl
    property string cfg_AudioUrl

    QQC2.ComboBox {
        id: palette
        Kirigami.FormData.label: "Palette:"
        model: ["Drift through all"].concat(Moods.names())
    }
    RowLayout {
        Kirigami.FormData.label: "Full colour cycle:"
        enabled: palette.currentIndex === 0
        QQC2.Slider { id: cycle; from: 1; to: 24; stepSize: 0.5 }
        QQC2.Label { text: cycle.value.toFixed(1) + " h" }
    }
    QQC2.CheckBox {
        id: music
        Kirigami.FormData.label: "Music:"
        text: "Move to the music that's playing, and take its cover's colours while drifting"
    }
    QQC2.CheckBox {
        id: video
        enabled: music.checked && palette.currentIndex === 0
        text: "On a portrait screen, take the main colour of the YouTube video on screen, as it plays"
    }
    QQC2.CheckBox {
        id: fuse
        enabled: music.checked
        text: "Two waxes merging make a new colour while music plays (wild)"
    }
    QQC2.ComboBox {
        id: fusion
        Kirigami.FormData.label: "Fusing wax turns to:"
        enabled: music.checked && fuse.checked
        model: ["A neighbouring colour", "The palette's opposite", "The third wax's colour"]
    }
    RowLayout {
        Kirigami.FormData.label: "Speed:"
        QQC2.Slider { id: speed; from: 0.2; to: 5; stepSize: 0.1 }
        QQC2.Label { text: speed.value.toFixed(1) + "×" }
    }
    RowLayout {
        Kirigami.FormData.label: "Brightness:"
        QQC2.Slider { id: brightness; from: 0.3; to: 1.6; stepSize: 0.05 }
        QQC2.Label { text: Math.round(brightness.value * 100) + "%" }
    }
    QQC2.SpinBox {
        id: fps
        Kirigami.FormData.label: "Frames per second:"
        from: 5; to: 60
    }
    QQC2.CheckBox {
        id: pause
        Kirigami.FormData.label: "Pause:"
        text: "When a maximized or fullscreen window covers the screen"
    }
}
