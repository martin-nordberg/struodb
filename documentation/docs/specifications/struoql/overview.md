# 1. StruoQL — Overview

## 1.1 Data Flow Through StruoDB

In StruoDB events are inserted into streams maintained by **"event 
collectors"** - edge nodes of the distributed database where events 
are first stored. Next events from multiple event collectors are
combined in **"event aggregators"**, which also aggregate streams with 
one another. Finally, event streams are projected into table-like
projections that are queryable much like ordinary SQL tables. 
Projections are maintained by **"event projectors"**.

StruoQL (StruoDB Query Language) consists of three small sub-languages:
1. a small sub-language for defining event stream schemas, 
2. a simple sub-language for creating events that 
adhere to a stream's schema, and 
3. a much more elaborate sub-language for
defining projections that reinterpret one or more streams
over time and with various mechanisms for combining knowledge
originating from multiple event collectors. 

Projections allow for processing events in several ways:
* as time series, including statistical summaries, 
* as commands acting on a shared domain model, with CQRS- and CRDT-styled 
   coordination of events and queries, or 
* as searchable event streams with added indexing, 
   accumulators, and so on.

Event streams and projections are stored in PostgreSQL tables and views.
To that end StruoQL statements transpile to PostgreSQL statements
behind the scenes. The language follows PostgreSQL's own
conventions (case folding, quoting, comment syntax) so that the language
feels native to anyone who already knows SQL, and so that the 
StruoQL transpiler stays close to a straightforward syntactic mapping.

## 1.2 Lexical Structure

The three sub-languages of StruoQL share a common lexical structure
specified in §2. The lexical tokens of StruoQL differ little from 
standard SQL except for the addition of keywords like "STREAM" and
"PROJECTION". Projections have the largest share of custom lexical 
structure.

## 1.3 Schema Definition

Event streams have schemas much like PostgreSQL tables except
that they add system-generated fields for event source and time 
to automatically ensure event uniqueness and overall ordering across
a distributed StruoDB system.

**CREATE STREAM** and **ALTER STREAM** statements
define the evolution of a stream's schema. See §3.

## 1.4 Event Creation

Data enters StruoDB through event creation commands (defined in §4) 
that are barely 
distinguishable from ordinary SQL **INSERT** statements. Event fields must 
match the schema of the stream into which they are inserted.

### 1.1.4 Projections

*TODO*
