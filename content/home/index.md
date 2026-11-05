+++
title = "JessQL"
description = "A Luau relational query engine for Jess with native JSL persistence, synchronized WAL transactions and immutable generations."
date = 2026-10-21

[taxonomies]
tags = ["Jess", "Luau"]

[extra]
sections = ["overview", "releases", "credits"]
+++

A Luau relational query engine for Jess with native JSL persistence, synchronized WAL transactions and immutable generations.

<!-- more -->

A [Jess](https://github.com/DreamWeave-MP/jess) package, `org.dreamweave.jessql`. Add it to a `jess.toml` and
`jess workspace sync` pins it from this site:

```toml
[dependencies]
"org.dreamweave.jessql" = "0.2"
```

Every release below is the package's own archive, with its content digest beside the archive's
SHA-256; `jess.lock` pins the first and checks both.
