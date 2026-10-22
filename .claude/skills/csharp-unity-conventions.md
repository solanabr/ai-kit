---
name: csharp-unity-conventions
description: "C# and Unity constraints a model gets wrong: global.json SDK pinning, Unity's C# 9 ceiling, main-thread async and Awaitable, serialization rules, asmdefs, IL2CPP stripping, and Solana.Unity-SDK defaults."
---

# C# and Unity conventions

Checked 2026-10-22 against the Unity 6.6 (6000.6) manual, Microsoft's global.json reference (updated 2026-04-30) and Solana.Unity-SDK `main` (package 1.3.0; latest release tag v1.2.9). Naming and style live in [csharp-patterns.md](ext/solana-game/skill/csharp-patterns.md) (install: `bash .claude/bin/skills.sh add solana-game`); this file holds what a build or a player breaks on.

## Two compilers, two rule sets

A Unity project compiles with the Roslyn that ships inside the Editor, not with the `dotnet` SDK on the machine. Know which one a file goes through before choosing syntax.

- **Unity (every Unity 6 release through 6.6): C# 9.0.** C# 10+ does not compile: no file-scoped namespaces, `global using`, primary constructors, collection expressions (`[1, 2]`), `required` members or raw string literals. csharp-patterns.md's "Modern C# (12/13)" section applies to plain .NET projects only.
- Within C# 9, Unity rejects init-only setters, covariant returns and module initializers. Records need a hand-declared `namespace System.Runtime.CompilerServices { internal static class IsExternalInit {} }`, and never go in a serialized type.
- API surface follows Player Settings > Api Compatibility Level (.NET Standard 2.1 by default, or .NET Framework). A NuGet DLL built for `net6.0+` will not load; take its `netstandard2.0`/`2.1` build.
- **Code shared between Unity and a .NET backend** (account layouts, instruction builders): a `netstandard2.1` class library with `<LangVersion>9.0</LangVersion>` in its `.csproj`, so the backend build fails the moment someone writes syntax Unity cannot compile.

## global.json (plain .NET projects and the tooling around Unity)

Unity ignores `global.json`. The `dotnet` CLI does not — `dotnet build`/`test` for a backend, a shared library or a Solnet tool, and the C# language server. Without one, the highest installed SDK wins, previews included outside Visual Studio, so two machines build with different SDKs.

```json
{ "sdk": { "version": "10.0.100", "rollForward": "latestFeature", "allowPrerelease": false } }
```

- If the repo has one, use its version; don't edit it to make a build pass. `version` takes a full `x.y.znn` only — no `10.0`, wildcards or ranges.
- `rollForward` defaults to `patch` when a version is set. `latestFeature` allows newer feature bands and patches within the major.minor; `disable` demands an exact match and is the setting to use with NuGet lock files.
- The CLI searches upward from the **current working directory**, MSBuild's resolver from the solution or project directory: put it at the repo root, beside the `.sln`. In CI, `actions/setup-dotnet` with `global-json-file: global.json` installs that SDK.

## Async on the main thread

- Unity's synchronization context resumes awaits in a MonoBehaviour on the main thread; after `ConfigureAwait(false)`, `Task.Run` or an SDK WebSocket callback you are on a pool thread and any Unity API call throws or misbehaves.
- `Awaitable` (Unity 2023.1+, so Unity 6): pooled — **never await one instance twice** (undefined behaviour: exception or deadlock). Switch threads with `await Awaitable.BackgroundThreadAsync()` / `await Awaitable.MainThreadAsync()`. It has no `WhenAll`/`WhenAny`; use `Task` or UniTask for those.
- **Solana.Unity-SDK vendors UniTask 2.5.0** (`com.cysharp.unitask`) inside its package. Adding UniTask separately via UPM or OpenUPM duplicates the `UniTask` assembly and the project stops compiling; use the SDK's copy. Its fire-and-forget idiom is `.Forget()`, not `async void`.
- WebGL has no threads: `BackgroundThreadAsync`, `Task.Run` and `.Result`/`.Wait()` give no parallelism or freeze the page.

## Serialization

- Serialized: `public` or `[SerializeField]` fields that are not `static`, `const` or `readonly`, of primitive, Unity, `[Serializable]` or `UnityEngine.Object` types, plus arrays and `List<T>` of those.
- Not serialized: properties (use `[field: SerializeField]`; the stored name is `<Prop>k__BackingField`, so a rename needs `[field: FormerlySerializedAs("<Old>k__BackingField")]`), dictionaries, multidimensional and jagged arrays, nested containers. Wrap them, or implement `ISerializationCallbackReceiver`.
- Inline serialization cannot hold null — a null `[Serializable]` field comes back as an empty instance — and drops polymorphism (a derived object reloads as the base type). `[SerializeReference]` gives null, shared references and polymorphism, at a cost.
- `JsonUtility` follows the same rules (no dictionaries, no top-level arrays, no properties). For RPC JSON use Newtonsoft (`com.unity.nuget.newtonsoft-json`, which the SDK already depends on).

## Assemblies and stripping

- Code outside an `.asmdef` lands in `Assembly-CSharp`, which no asmdef can reference. Give game code a runtime asmdef that references the SDK's runtime assembly (defined by its `Runtime/com.solana.unity_sdk.asmdef`) and, if you await UniTask, the vendored `UniTask` one; an Editor asmdef includes the Editor platform only, or the player build fails on `UnityEditor` references.
- IL2CPP (mandatory for WebGL and iOS, usual for Android) cannot disable managed stripping; its default is Minimal (Mono's is Disabled). Types reached only through reflection — Newtonsoft deserialization of your account and RPC DTOs — work in the Editor and vanish in the player. Preserve them with `[Preserve]` or an `Assets/link.xml`, and test an IL2CPP build, not only Play Mode.

## Solana.Unity-SDK defaults that bite

- Install by git URL, pinned: `https://github.com/magicblock-labs/Solana.Unity-SDK.git#vX.Y.Z`. The package id in `Packages/manifest.json` is `com.solana.unity_sdk` (underscore). Namespace `Solana.Unity.SDK`.
- The `Web3` component's `rpcCluster` defaults to **DevNet**: a mainnet build must set it, or `customRpc`, explicitly. A second `Web3` in a scene is destroyed in `Awake`; `Web3.Instance` is null until then, so subscribe via `Web3.OnWalletInstance` or in `Start`.
- `Web3.Rpc`, `Web3.WsRpc`, `Web3.Account`, `Web3.Wallet` are null before login; `Web3.Base` is obsolete. Login: `LoginWalletAdapter()` (browser and MWA), `LoginInGameWallet(password)`, `LoginWeb3Auth(...)`; react through `Web3.OnLogin` / `OnLogout`.
- `Web3.BlockHash()` defaults to `useCache: true` at `Confirmed`: when re-signing after expiry, pass `useCache: false` or you sign with the same stale blockhash.
- The wallet's built-in RPC limiter defaults to `RpcMaxHits = 30`, `RpcMaxHitsPerSeconds = 1`; NFT loading also waits at least 100 ms between requests on WebGL. Raise the limits for a paid RPC instead of adding your own retry loop on top.
- A `wss://` endpoint goes in `webSocketsRpc`; an `http(s)` URL there does not work. Android builds need Custom Main Gradle Template enabled to avoid duplicate-class errors.
