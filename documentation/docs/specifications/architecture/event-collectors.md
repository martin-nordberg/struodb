# 3. StruoDB Architecture — Event Collectors

## 3.1 Event Collector Variations

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

# 3.2 Event Collector Software Components

* **Event Store** - The composite component that stores and forwards events.
* **StruoQL Over HTTP** - For a Bun service event collector, accepts event
  creation (INSERT) commands via HTTP.
