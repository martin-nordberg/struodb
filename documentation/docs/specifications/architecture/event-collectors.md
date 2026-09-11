# 3. StruoDB Architecture — Event Collectors

## 3.1 Supporting Changes in Existing Specs and Code

* The Event Store component together with its transitive dependencies are modified
  to return information about configured aggregators and counts of events - total
  and pending per aggregator. These changes support the admin endpoint in 3.3.1
  below.
* The Event Store, Event Creation, and Database Repository components need modification
  to return results per INSERT statement when multiple INSERT statements are executed 
  at once per the response specified in 3.3.1  event creation.

## 3.2 Event Collector Variations

* **Web Browser Application** - The event collector is deployed as library code 
  within a larger JavaScript application running in a web browser. Events
  originate from user interaction with the browser.
* **Bun or NodeJS Application** - A custom JavaScript applications run in a 
  container or on a server. The application itself originates events by
  whatever mechanism is relevant for its domain (*e.g.* the event collector 
  node is the software controlling a specialized sensor).
* **Bun Service (with HTTP clients)** - A general purpose event collector
  operates as a web service collecting events from one or more external 
  clients who send event creation commands via HTTP calls.

## 3.3 Event Collector Software Components

* **Event Store** - The composite component that stores and forwards events.
* **StruoQL Over HTTP** - For a Bun service event collector, accepts event
  creation (StruoQL INSERT) commands via HTTP.

### 3.3.1 StruoQL Over HTTP

* Name: http-event-creation
* Path: ./services/http-event-creation
* Type: Shared Library
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - Hono
  - event-store
* Event Creation Endpoint
  - URL - POST <base>/api/events 
  - Content-Type: text/plain (StruoQL INSERT queries)
  - Response: 
    - A JSON array of responses, one array entry per INSERT statement:
      - If the INSERT has a RETURNING clause, a JSON array of the RETURNING result rows
      - Otherwise, a count of the number of events inserted
* Admin Endpoint
  - URL - GET <base>/api/admin
  - Response: JSON containing the following:
    - List of stream objects by name
    - Each stream object includes stream name, schema migration step count,
      currently stored event count [SELECT COUNT(*) FROM <stream_name>], 
      configured aggregator IDs, count of pending aggregations per aggregator 
      [SELECT COUNT(*) FROM _struo_<stream_name>_pending_aggregations GROUP BY aggregator_node_id].
* Authentication: Deferred for later work

### 3.3.2 General Purpose Event Collector (Bun Service)

* Name: event-collector-service
* Path: ./services/event-collector-service
* Type: Bun Application (Web Service)
* Language: TypeScript
* Runtime: Bun
* Dependencies:
  - http-event-creation
  - event-store
* Configuration: Command line argument giving the config file path
* Notes:
  - Shutdown (SIGTERM) gracefully shuts down the event store (waiting for work in progress,
    stopping timers, and closing the database)
