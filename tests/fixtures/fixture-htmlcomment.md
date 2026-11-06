# Fixture: a fence marker inside an HTML comment

The comment's contents are literal text, so the `text` fence below is not an
opener. The shell block after the comment is real, and its body is broken — a
parser that opens a block on that fence swallows this file's only real block
and reports nothing at all.

<!--
```text
-->
```bash
if
```
