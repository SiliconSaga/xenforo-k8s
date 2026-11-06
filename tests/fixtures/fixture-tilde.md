# Fixture: a tilde-fenced shell block with a syntax error

CommonMark allows `~~~` as well as backticks, and more than three of either.
A parser that only knows ```` ``` ```` never looks inside this block at all.

~~~~bash
if
~~~~
