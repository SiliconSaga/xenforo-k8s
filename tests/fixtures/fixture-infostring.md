# Fixture: an inline code span that looks like a fence

A backtick fence's info string cannot contain a backtick (CommonMark 4.5), so
the line below is a code span in a sentence, not an opener. Taken as one it
swallows the broken block that follows.

```text``` describes the format.

```bash
if
```
