---
description: "Run C# tests: Unity Test Framework in batchmode, or dotnet test"
---

Run the C# test suites and summarize failures. `$ARGUMENTS` can name a platform (`editmode`, `playmode`) and a filter (class, method, or category).

Unity test structure, naming, test doubles and async patterns: [solana-game testing.md](../skills/ext/solana-game/skill/testing.md) (install first: `bash .claude/bin/skills.sh add solana-game`).

## Unity

Run tests through the editor. The `.csproj` and `.sln` files Unity generates are for IDEs; `dotnet test` cannot build them.

`<unity> -batchmode -nographics -projectPath . -runTests -testPlatform EditMode -testResults TestResults/editmode.xml -logFile TestResults/editmode.log`

- `<unity>` is the editor matching `m_EditorVersion` in `ProjectSettings/ProjectVersion.txt`: `/Applications/Unity/Hub/Editor/<version>/Unity.app/Contents/MacOS/Unity` on macOS, `C:\Program Files\Unity\Hub\Editor\<version>\Editor\Unity.exe` on Windows. GameCI images ship it as `unity-editor`.
- Leave out `-quit`: the test runner closes the editor when the run ends, and `-quit` can end it before tests run. Close any editor that has the project open, or batchmode fails on the project lock.
- `-testPlatform PlayMode` for PlayMode tests; drop `-nographics` if they render. Narrow with `-testFilter "Ns.Class.Method"` (semicolon list or regex), `-testCategory "Unit;!Integration"` (the `!` skips network-bound tests), or `-assemblyNames "Game.Tests"`.
- No results XML means the run died before any test ran, usually on a compile error: search the log for `error CS`. The XML is NUnit 3: totals sit on the root `<test-run>` (`total`, `passed`, `failed`), and each failure is a `<test-case result="Failed">` with `<failure><message>` and `<stack-trace>`. Count `Inconclusive` as failed.
- Tests not discovered: test assemblies cannot reference the default `Assembly-CSharp`, so game code needs its own `.asmdef`. The test `.asmdef` references it plus `UnityEngine.TestRunner` and `UnityEditor.TestRunner`, adds `nunit.framework.dll` through `overrideReferences`, and sets `defineConstraints: ["UNITY_INCLUDE_TESTS"]`; EditMode test assemblies also set `includePlatforms: ["Editor"]`.

## .NET services

1. `dotnet restore` after a clone or any change to `.csproj`, `.sln`, `Directory.Packages.props` or `packages.config`.
2. `dotnet build --no-restore --nologo -v minimal`, then `dotnet test --no-build --nologo -v minimal`. Narrow with `--filter "FullyQualifiedName~WalletService"`, `"Category=Unit"` (NUnit; xUnit filters on trait names, MSTest on `TestCategory`), or combinations such as `"Name~Connect&Category!=Integration"`.
3. Show only failures: `dotnet test --no-build -v normal | rg -e "Failed" -e "Error Message:" -e "Stack trace:" -C 4`.

## Fix loop

Fix, rebuild, retest. If the same error survives two attempts, stop and show the user the error output and the change you tried instead of guessing further.

## Output

Pass, fail and skip counts per platform or project, then each failing test with its message and the first stack frame in project code.
