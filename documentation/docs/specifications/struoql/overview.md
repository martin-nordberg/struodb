# 1. Struo Query Language — Overview

## 1.1 Status

Part I specifies the **lexical structure** (keywords, identifiers, literals,
operators/punctuation, comments) of the StruoDB query language. Part II
specifies its **grammar**: expressions and function calls (§3.2), which
`CREATE STREAM` (§3.3), `ALTER STREAM` (§3.4), and `INSERT` (§4.1) all depend
on, plus those three statements themselves — only querying or subscribing
to a stream's events is still out of scope (see §3.1, §5). See
[Design Decisions](/specifications/struoql/design-decisions) for settled points not
fully reflected below, and its "Open Issues" section for what's still
undecided.

## 1.2 Purpose

StruoDB is an event-stream-oriented query language that transpiles to
PostgreSQL. Where this spec is silent, the language follows PostgreSQL's own
conventions (case folding, quoting, comment syntax) so that the language
feels native to anyone who already knows SQL, and so the transpiler can stay
close to a straightforward syntactic mapping.

