# Embedded SuperCollider App Engine

This is Mat Dalgleish’s SuperCollider App Engine 0.2.0, the host-neutral C ABI edition of the GodotCollider transplant. Pelagic Orbits builds the original portable engine and C ABI wrapper in `src/` as a static library. Runtime resources sit under `runtime/supercollider/`. `libscsynth` and `libweldsclang` load directly into the game process. Controls use the engine’s C ABI, which queues server commands inside the World. AVFoundation plays the stereo buffers it returns.

The supplied binaries target Apple Silicon and macOS 15. The matching SuperCollider source is based on upstream revision `ae4ddb74ba5baacc94509fb671913458b8a07299`, with the Alchemy host-audio and GodotCollider shutdown patches from the original project. The language bridge starts with its default UDP listener disabled. The applied patches are in `upstream/`, alongside the patched source archive and its bundled build dependencies. The required UGen modules are loaded from the app bundle.

To rebuild the runtime, unpack the source archive and run the following from its parent directory. Copy the resulting `libscsynth.1.0.0.dylib` as `libscsynth.dylib` and `libweldsclang.dylib` into `runtime/supercollider/lib/`. Copy the selected `.scx` files to `runtime/supercollider/plugins/`.

```sh
cmake -S supercollider-source -B supercollider-build -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
  -DLIBSCSYNTH=ON -DAUDIOAPI=host -DNO_LIBSNDFILE=ON -DSUPERNOVA=OFF \
  -DSCLANG_SERVER=OFF -DSC_EL=OFF -DSC_QT=OFF -DSC_IDE=OFF -DSC_VIM=OFF \
  -DSC_ABLETON_LINK=OFF -DNATIVE=OFF -DBUILD_TESTING=OFF
cmake --build supercollider-build --parallel --target libscsynth weldsclang \
  OscUGens LFUGens IOUGens MulAddUGens BinaryOpUGens UnaryOpUGens \
  NoiseUGens FilterUGens TriggerUGens PanUGens DelayUGens ReverbUGens
```

See [the engine licence](licenses/LICENSE.md) and [third-party notices](licenses/THIRD_PARTY_NOTICES.md).
