# Running NexaAid on the Android emulator

Everyone develops and takes PR screenshots on the **same emulator**, so
screens look the same for every reviewer.

## One-time setup

1. Install Android Studio, then open **More Actions > SDK Manager** and
   install **Android 14 (API 34)** and **Android Emulator**.
2. Open **More Actions > Virtual Device Manager > Create device**.
   Pick **Pixel 8**, system image **API 34 (Google APIs)**, finish.
3. Check Flutter sees everything:
   ```
   flutter doctor
   flutter emulators
   ```
   Windows: if the emulator is slow or won't start, turn on
   **Windows Hypervisor Platform** in "Turn Windows features on or off".

## Every day

Terminal 1, the backend (from `backend/app`):
```
uvicorn main:app --reload
```

Terminal 2, the app (from `mobile`):
```
flutter pub get
flutter emulators --launch <id from "flutter emulators">
flutter run
```
While it runs: `r` = hot reload (keeps state), `R` = hot restart,
`q` = quit.

The emulator reaches your PC at `http://10.0.2.2:8000`, which is the
app's default. To change it, tap the gear icon on the landing page.

### Real phone over USB
```
adb reverse tcp:8000 tcp:8000
```
Then set the server address to `http://localhost:8000`.

## Checks before every PR screenshot

Dark mode and large text are part of the definition of done.

| Check | How |
|---|---|
| Dark mode | Profile > Appearance > Dark, or `adb shell cmd uimode night yes` |
| Large text | `adb shell settings put system font_scale 2.0` (reset: `1.0`) |
| Screenshot | `flutter screenshot` while the app runs, or the camera button on the emulator toolbar |

Compare your screen with **Profile > Developer tools > Design system
gallery**. It has the same dark-mode and text-size switches.

## Common problems

| Problem | Fix |
|---|---|
| "Can't reach the server" | Is uvicorn running? Is the server address `http://10.0.2.2:8000`? |
| Fonts look like Roboto | The emulator has no internet. Fonts download on first run; check the emulator's Wi-Fi. |
| `flutter run` picks Chrome | `flutter run -d emulator-5554` (see `flutter devices`) |
| Build fails after pulling | `flutter clean && flutter pub get` |
