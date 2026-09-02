# Struo Query Language — Overview

## Status

Part I specifies the **lexical structure** (keywords, identifiers, literals,
operators/punctuation, comments) of the StruoDB query language. Part II
specifies its **grammar**: expressions and function calls (§8), which
`CREATE STREAM` (§9), `ALTER STREAM` (§10), and `INSERT` (§11) all depend
on, plus those three statements themselves — only querying or subscribing
to a stream's events is still out of scope (see §7, §12). See
[Design Decisions](/struoql/design-decisions) for settled points not
fully reflected below, and its "Open Issues" section for what's still
undecided.

## Purpose

StruoDB is an event-stream-oriented query language that transpiles to
PostgreSQL. Where this spec is silent, the language follows PostgreSQL's own
conventions (case folding, quoting, comment syntax) so that the language
feels native to anyone who already knows SQL, and so the transpiler can stay
close to a straightforward syntactic mapping.

