# LibSignalSPM

Swift Package Manager wrapper for [libsignal](https://github.com/signalapp/libsignal).

Built from [nicegram/nicegram-libsignal](https://github.com/nicegram/nicegram-libsignal) fork.

## Usage

```swift
.package(url: "https://github.com/sundayfun/LibSignalSPM.git", from: "0.76.3"),
```

Then depend on `LibSignalClient`:

```swift
.product(name: "LibSignalClient", package: "LibSignalSPM")
```

## Updating

```bash
./Scripts/build-and-release.sh v0.77.0
```
