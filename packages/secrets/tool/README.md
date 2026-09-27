# Key-material boundary gate

Run `make custody-check` from the repository root. The existing JavaScript gate checks access to the keystore and package internals. `key_material_gate.dart` additionally resolves production Dart references with the workspace's pinned analyzer and rejects known private derivation and RecoverBull decryption entry points outside `packages/secrets`.

The gate scans `lib/`, `packages/*/lib/` and `features/*/lib/`, excluding the custody package, generated files, vendor code and build output. Resolution errors fail the check; diagnostics print only file names, diagnostic identifiers and declaration identities, never source excerpts or runtime values. Import prefixes, re-exports, type aliases, constructor tear-offs, method tear-offs and dot shorthand keep the identity of their resolved declaration.

Exceptions identify a file, enclosing function or class method, and individual permitted symbols. `_performDryScan` can derive from pre-import user input. `SwapMasterKeyModel.fromBoltz` and `toBoltz` can translate the deliberately exported swap child key. Neither exception permits deriving a new child from wallet words. BIP85 child mnemonic formatting, BIP39 validation and public-key operations are not private derivation and need no exception.

This is a policy over known APIs, not whole-program dataflow analysis. It does not prove that plaintext never leaves the package, distinguish private from public inputs to mixed APIs such as `Bip32Keys.fromBase58`, or detect a newly introduced cryptographic implementation. Review cryptographic dependency and API changes together with this policy. Unresolved access to the listed sensitive members, including dynamic access, fails closed; other dynamic dispatch remains outside the guarantee.

`test/key_material_gate_test.dart` resolves regression fixtures against the installed dependencies without executing their cryptographic or native APIs.
