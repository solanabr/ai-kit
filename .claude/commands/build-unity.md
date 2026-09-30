---
description: "Build the Unity project in batchmode for WebGL, desktop, Android or PSG1"
---

Build the Unity project for the target in $ARGUMENTS: `webgl` (default), `win64`, `osx`, `android` or `psg1`. References: [solana-game SKILL.md](../skills/ext/solana-game/skill/SKILL.md), [unity-sdk.md](../skills/ext/solana-game/skill/unity-sdk.md) (wallet login per platform), [playsolana.md](../skills/ext/solana-game/skill/playsolana.md) (PSG1 build configuration); install them first with `bash .claude/bin/skills.sh add solana-game`.

## Steps

1. Find the editor for the version in `ProjectSettings/ProjectVersion.txt`: macOS `/Applications/Unity/Hub/Editor/<version>/Unity.app/Contents/MacOS/Unity`, Windows `C:\Program Files\Unity\Hub\Editor\<version>\Editor\Unity.exe`, Linux `~/Unity/Hub/Editor/<version>/Editor/Unity`. The `unity-editor` command exists only in GameCI images.
2. Check that `Packages/manifest.json` lists `com.solana.unity-sdk` (plus `com.playsolana.sdk` for PSG1) and that the target's platform module (WebGL or Android Build Support) is installed.
3. Use `Assets/Editor/BuildScript.cs` if it exists. Otherwise create it with one static method per target that builds the enabled scenes from `EditorBuildSettings.scenes` into `Build/<Platform>/` and calls `EditorApplication.Exit(1)` when `report.summary.result != BuildResult.Succeeded`. Without that call, batchmode exits 0 on a failed build.
4. Run `<Unity> -quit -batchmode -nographics -projectPath . -buildTarget <target> -executeMethod BuildScript.<Method> -logFile build.log` (`-logFile -` streams to stdout). CLI target names are `WebGL`, `Win64`, `OSXUniversal`, `Linux64` and `Android`, unlike the C# enum (`BuildTarget.StandaloneWindows64`, `BuildTarget.StandaloneOSX`). On failure, search `build.log` for `error CS` and the build report errors.
5. PSG1 builds for Android: ARM64 only (which requires the IL2CPP backend), minimum API level 30, portrait orientation (1080x1240), Vulkan plus GLES3, package ID `com.playsolana.games.<game>`, and the `PLAYSOLANA_PSG1` scripting define. Set these in the build method; playsolana.md has the settings snippet. Add PSG1 code paths only when the user targets PSG1.

## Failure fixes

- WebGL player fails to load: Brotli or gzip output needs the server to send `Content-Encoding`, or enable Decompression Fallback. Serve over http(s), not `file://`. Wallet login (`LoginWalletAdapter`) needs a browser wallet extension, so test it in the served build rather than the editor.
- Works in the editor but RPC or JSON deserialization fails in the player: IL2CPP stripped the types. Lower Managed Stripping Level or add a `link.xml` that preserves the SDK assemblies.

## Output

Target, Unity version, output path and size, and the errors from `build.log` if the build failed.
