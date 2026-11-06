# Fixture: `<!--` inside inline code is not a comment block

An HTML comment block has to begin a line (CommonMark 4.6 type 2). A parser
that matches `<!--` anywhere enters comment mode here and stays there until
some later line happens to contain the closer, skipping everything between.

Hide a section with `<!--` and close it with `-->` when you need to.

```bash
if
```

That `-->` above must not have reopened anything either.
