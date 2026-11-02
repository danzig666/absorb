# Test signing key

`absorb-dev-test.jks` signs the **Absorb Dev** test builds that the Test APK
workflow publishes, so each one installs over the last. Alias `absorbtest`,
store and key password `absorbtest`.

It is public on purpose and only ever signs the dev flavor
(`com.barnabas.absorb.dev`). Anyone can sign an APK with it, so only install
Absorb Dev builds from this repository's releases.
