# Fixture: a valid block closed by a longer fence

CommonMark lets a closing fence be longer than its opener. The block below is
perfectly good shell and must not be reported as unterminated.

```bash
echo "valid"
````
