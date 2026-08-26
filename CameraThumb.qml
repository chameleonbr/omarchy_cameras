// A camera thumbnail that refreshes without blinking.
//
// Setting Image.source clears the element while the new file loads, so a
// polled JPEG flashes empty on every tick and the feed reads as a slideshow of
// stills rather than movement. Two Images solve it: the hidden one loads the
// next frame and they only swap once it is Ready, so there is always a painted
// frame on screen.

import QtQuick
import "Cameras.js" as Cameras

Item {
  id: root

  property var camera: null
  // Bumped by the owner on a timer; each bump is one new frame.
  property int tick: 0
  property bool active: true

  readonly property bool hasFrame: front.status === Image.Ready
  property bool _frontIsA: true

  readonly property Image front: _frontIsA ? imageA : imageB
  readonly property Image back: _frontIsA ? imageB : imageA

  onTickChanged: load()
  onCameraChanged: {
    // Only a *different* camera has nothing to hold over. `cameras` is rebuilt
    // from scratch on every refresh, so comparing the objects would drop the
    // painted frame each time the panel opens and blank the whole grid until
    // the next fetch lands — which is exactly the delay this component exists
    // to avoid.
    var id = camera ? String(camera.id) : ""
    if (id !== _loadedId) {
      imageA.source = ""
      imageB.source = ""
      _frontIsA = true
      _loadedId = id
    }
    load()
  }

  property string _loadedId: ""

  function load() {
    if (!active || !camera) return
    back.source = Cameras.thumbSource(camera, tick)
  }

  Component.onCompleted: load()

  Image {
    id: imageA
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    // Each tick is a distinct URL, so the cache would only ever hold frames
    // that are already stale.
    cache: false
    opacity: root._frontIsA ? 1 : 0
    onStatusChanged: if (status === Image.Ready && !root._frontIsA) root._frontIsA = true
  }

  Image {
    id: imageB
    anchors.fill: parent
    fillMode: Image.PreserveAspectCrop
    asynchronous: true
    cache: false
    opacity: root._frontIsA ? 0 : 1
    onStatusChanged: if (status === Image.Ready && root._frontIsA) root._frontIsA = false
  }
}
