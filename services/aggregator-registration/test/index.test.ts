import { describe, expect, test } from "bun:test";
import {
  AggregatorRegistrationError,
  handleRegister,
  registerWithAggregator,
} from "../src/index.ts";

describe("registerWithAggregator", () => {
  test("returns the migration on a successful response", async () => {
    const fakeFetch = (async (input: string | URL, init?: RequestInit) => {
      expect(String(input)).toBe(
        "https://aggregator.example.com/streams/sensor_reading/register",
      );
      expect(init?.method).toBe("POST");
      return new Response(JSON.stringify({ migration: "CREATE STREAM ...;" }), {
        status: 200,
      });
    }) as typeof fetch;

    const result = await registerWithAggregator(
      { baseUrl: "https://aggregator.example.com" },
      "sensor_reading",
      fakeFetch,
    );
    expect(result.migration).toBe("CREATE STREAM ...;");
  });

  test("URL-encodes the stream name", async () => {
    const fakeFetch = (async (input: string | URL) => {
      expect(String(input)).toContain("streams/a%20b/register");
      return new Response(JSON.stringify({ migration: "" }), { status: 200 });
    }) as typeof fetch;

    await registerWithAggregator({ baseUrl: "https://x" }, "a b", fakeFetch);
  });

  test("throws AggregatorRegistrationError on a non-2xx response", async () => {
    const fakeFetch = (async (_input: string | URL, _init?: RequestInit) =>
      new Response("stream not found", { status: 404 })) as typeof fetch;

    await expect(
      registerWithAggregator({ baseUrl: "https://x" }, "unknown", fakeFetch),
    ).rejects.toThrow(AggregatorRegistrationError);
  });
});

describe("handleRegister", () => {
  test("returns the migration when the stream is known", () => {
    const result = handleRegister("s", (stream) =>
      stream === "s" ? "CREATE STREAM s (a INT);" : undefined,
    );
    expect(result).toEqual({ migration: "CREATE STREAM s (a INT);" });
  });

  test("returns undefined for an unknown stream", () => {
    const result = handleRegister("unknown", () => undefined);
    expect(result).toBeUndefined();
  });
});
