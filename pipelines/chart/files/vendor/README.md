# Bundled YAML parser

`js-yaml.js` is the CommonJS-compatible distribution from js-yaml
4.3.0, MIT licensed (see js-yaml.LICENSE). Bundling avoids npm downloads in the
disconnected customer pipeline. Only trailing whitespace was normalized. This is an upstream library, not a claim of
Red Hat support or FIPS certification.

Source: https://registry.npmjs.org/js-yaml/-/js-yaml-4.3.0.tgz

Archive SHA-512:
`d6d77bf3c6809e7679aaced5d90211975a308ed6296cab7be3d637c5abaa420c0820617fc575b3d70313101c793b72cade55cb56ea973dd3f18f6068147696f5`

The archive digest was checked against npm's published integrity metadata.
Review upstream advisories before upgrading. The updater uses JSON_SCHEMA to
avoid executing custom YAML tags. YAML comments are not retained by this parser.
