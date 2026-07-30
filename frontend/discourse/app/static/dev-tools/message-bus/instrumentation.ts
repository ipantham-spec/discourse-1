import { trackedArray, trackedObject } from "@ember/reactive/collections";
import "message-bus-client";

/**
 * Observation of MessageBus that the library does not expose on its own.
 *
 * The subscription list is already public: `MessageBus.callbacks` is the live
 * array, so channels, positions and subscription counts can simply be read.
 * What cannot be read is who registered a subscription, how long its callback
 * takes, whether it threw, and what arrived over a chunked response. Those
 * require standing between MessageBus and its callers, which is what this
 * module does while dev tools are loaded.
 *
 * Everything here is read-only with respect to MessageBus' behaviour: every
 * wrapper passes its arguments through untouched, returns what the original
 * returned, and rethrows what it threw.
 *
 * @module discourse/static/dev-tools/message-bus/instrumentation
 */

/**
 * A subscriber callback.
 *
 * MessageBus calls one with the message data plus the global and message ids,
 * but a subscriber is free to declare fewer parameters, and the wrappers below
 * relay whatever they were called with and return whatever came back.
 */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type MessageBusSubscriber = (...args: any[]) => unknown;

/** A subscription as MessageBus records it in its public `callbacks` array. */
interface MessageBusSubscription {
  channel: string;
  last_id: number;
  func: MessageBusSubscriber;
}

/** The request adapter MessageBus calls to run its long poll. */
type MessageBusAjax = (options: MessageBusAjaxOptions) => unknown;

/** The parts of a long poll request this module reads. */
interface MessageBusAjaxOptions {
  messageBus?: { chunked?: boolean };
  xhr?: () => XMLHttpRequest;
}

/** The parts of the MessageBus client this module stands in front of. */
interface MessageBusClient {
  callbacks: MessageBusSubscription[];
  subscribe: (
    channel: string,
    func: MessageBusSubscriber,
    lastId?: number
  ) => MessageBusSubscriber;
  unsubscribe: (channel: string, func?: MessageBusSubscriber) => boolean;
  ajax: MessageBusAjax;
  longPoll?: { abort: () => void } | null;
}

// TODO(devxp-typescript-pending): `message-bus-client` ships no type
// declarations, so the global it installs is described here as the subset this
// module touches. Drop this once the package, or a core wrapper around it,
// provides its own types.
type MessageBusWindow = Window & { MessageBus?: MessageBusClient };

/** A message as it arrives in a response frame. */
interface MessageBusFrame {
  channel: string;
  message_id: number;
  global_id: number;
  data: unknown;
}

/** A message this module has observed arriving. */
export interface ObservedMessage {
  channel: string;
  messageId: number;
  globalId: number;
  data: unknown;
  receivedAt: number;
}

/** What is known about one subscription, accumulated as its callback runs. */
interface SubscriptionMeta {
  original: MessageBusSubscriber;
  channel: string;
  source: string | null;
  calls: number;
  errors: number;
  lastError: string | null;
  slowestMs: number;
}

/** The MessageBus methods replaced while installed, kept to restore them. */
interface ReplacedMethods {
  subscribe: MessageBusClient["subscribe"];
  unsubscribe: MessageBusClient["unsubscribe"];
  ajax: MessageBusAjax;
}

const MAX_MESSAGES = 200;

/**
 * Per-subscription detail, keyed by the wrapper registered with MessageBus.
 *
 * Many-to-one on purpose. One function is routinely subscribed to several
 * channels — `topic-tracking-state` alone does it four times — so a wrapper
 * cannot be looked up from its original. Only this direction is well defined.
 */
const metaByWrapper = new WeakMap<MessageBusSubscriber, SubscriptionMeta>();

const state = trackedObject({
  installed: false,
  messages: trackedArray<ObservedMessage>([]),
  polls: 0,
});

let originals: ReplacedMethods | null = null;
let underlyingAjax: MessageBusAjax | null = null;

/**
 * Observed state, for the inspector to render.
 *
 * @returns The tracked state object.
 */
export function messageBusState() {
  return state;
}

/**
 * Describes what is currently subscribed, newest registrations last.
 *
 * Read straight from the live `MessageBus.callbacks` array, so it reflects
 * subscriptions made before dev tools loaded as well as after.
 *
 * @returns One entry per subscription.
 */
export function subscriptions() {
  const callbacks = (window as MessageBusWindow).MessageBus?.callbacks ?? [];
  const perChannel = new Map<string, number>();

  for (const callback of callbacks) {
    perChannel.set(
      callback.channel,
      (perChannel.get(callback.channel) ?? 0) + 1
    );
  }

  const seenPerChannel = new Map<string, number>();

  return callbacks.map((callback) => {
    const meta = metaByWrapper.get(callback.func);
    // A channel can legitimately hold several subscriptions, so the channel
    // alone does not identify one. Numbering them within their channel gives
    // each row a key that survives a refresh.
    const ordinal = seenPerChannel.get(callback.channel) ?? 0;
    seenPerChannel.set(callback.channel, ordinal + 1);

    return {
      id: `${callback.channel}#${ordinal}`,
      channel: callback.channel,
      lastId: callback.last_id,
      // A channel with more than one subscription is legal, but it is also
      // what an unbalanced subscribe looks like, so it is worth surfacing.
      duplicated: perChannel.get(callback.channel) > 1,
      source: meta?.source,
      calls: meta?.calls ?? 0,
      errors: meta?.errors ?? 0,
      lastError: meta?.lastError,
      slowestMs: meta?.slowestMs ?? 0,
    };
  });
}

/**
 * Starts observing MessageBus. Safe to call more than once.
 */
export function install() {
  const bus = (window as MessageBusWindow).MessageBus;

  if (state.installed || !bus) {
    return;
  }

  originals = {
    subscribe: bus.subscribe,
    unsubscribe: bus.unsubscribe,
    ajax: bus.ajax,
  };

  underlyingAjax = bus.ajax;

  bus.subscribe = instrumentedSubscribe;
  bus.unsubscribe = instrumentedUnsubscribe;

  // An accessor rather than an assignment. The MessageBus instance initializer
  // replaces `ajax` outright, and it runs after the dev tools chunk has loaded,
  // so a plain assignment here would simply be overwritten. Routing later
  // assignments into `underlyingAjax` keeps this wrapper outermost whichever
  // order the two run in.
  Object.defineProperty(bus, "ajax", {
    configurable: true,
    enumerable: true,
    get: () => instrumentedAjax,
    set: (implementation: MessageBusAjax) => {
      underlyingAjax = implementation;
    },
  });

  // Subscriptions made before dev tools loaded are wrapped where they sit, so
  // that they report like any other. Their source is unknown: the call that
  // created them has already returned.
  for (const callback of bus.callbacks) {
    callback.func = wrapCallback(callback.func, callback.channel, null);
  }

  state.installed = true;
}

/**
 * Stops observing MessageBus and restores what it replaced.
 */
export function uninstall() {
  const bus = (window as MessageBusWindow).MessageBus;

  if (!state.installed || !bus) {
    return;
  }

  bus.subscribe = originals.subscribe;
  bus.unsubscribe = originals.unsubscribe;

  // Replace the accessor with a plain value again, carrying whatever
  // implementation was most recently assigned to it.
  Object.defineProperty(bus, "ajax", {
    configurable: true,
    enumerable: true,
    writable: true,
    value: underlyingAjax,
  });

  for (const callback of bus.callbacks) {
    const meta = metaByWrapper.get(callback.func);

    if (meta) {
      callback.func = meta.original;
    }
  }

  state.messages.length = 0;
  state.polls = 0;
  state.installed = false;
  originals = null;
}

/**
 * Wraps a subscriber so its calls can be counted and timed.
 *
 * @param original - The callback the caller passed to `subscribe`.
 * @param channel - The channel it was subscribed to.
 * @param source - Where it was subscribed from, if known.
 * @returns The wrapper to register in its place.
 */
function wrapCallback(
  original: MessageBusSubscriber,
  channel: string,
  source: string | null
) {
  const wrapper = function (this: unknown) {
    const meta = metaByWrapper.get(wrapper);
    const startedAt = performance.now();

    meta.calls++;

    try {
      // The return value matters: `publishToMessageBus` in the test helpers
      // awaits what subscribers return, so swallowing it would silently stop
      // tests waiting for asynchronous subscribers.
      // eslint-disable-next-line prefer-rest-params
      return original.apply(this, arguments);
    } catch (error) {
      meta.errors++;
      meta.lastError = error?.message ?? String(error);

      // MessageBus logs subscriber exceptions itself, so this must still
      // propagate or that logging stops happening.
      throw error;
    } finally {
      meta.slowestMs = Math.max(meta.slowestMs, performance.now() - startedAt);
    }
  };

  metaByWrapper.set(wrapper, {
    original,
    channel,
    source,
    calls: 0,
    errors: 0,
    lastError: null,
    slowestMs: 0,
  });

  return wrapper;
}

function instrumentedSubscribe(
  this: unknown,
  channel: string,
  func: MessageBusSubscriber,
  lastId?: number
) {
  const wrapper = wrapCallback(func, channel, captureSource());

  originals.subscribe.call(this, channel, wrapper, lastId);

  // `subscribe` returns the function it registered. Returning the original
  // instead keeps the wrapper invisible, so a caller that holds on to the
  // return value and unsubscribes with it still matches.
  return func;
}

/**
 * `unsubscribe`, reimplemented so that it matches on the original callback.
 *
 * MessageBus matches subscriptions by function identity, and no caller in
 * Discourse keeps the value `subscribe` returned — they all pass the same bound
 * method back. Delegating to the real implementation would therefore compare a
 * caller's function against the wrapper standing in for it, match nothing, and
 * leave the subscription in place. That would manufacture exactly the leaks
 * this tool exists to report.
 *
 * Translating the argument to "the" wrapper is not possible either, because one
 * function may be subscribed to many channels and so have many wrappers. Each
 * entry is therefore unwrapped and compared individually.
 *
 * The surrounding logic mirrors the original: trailing-`*` globbing, iterating
 * in reverse, removing every match rather than the first, and aborting the
 * in-flight long poll if anything was removed.
 */
function instrumentedUnsubscribe(channel: string, func?: MessageBusSubscriber) {
  const bus = (window as MessageBusWindow).MessageBus;
  let glob = false;

  if (channel.indexOf("*", channel.length - 1) !== -1) {
    channel = channel.substr(0, channel.length - 1);
    glob = true;
  }

  let removed = false;

  for (let i = bus.callbacks.length - 1; i >= 0; i--) {
    const callback = bus.callbacks[i];
    let keep;

    if (glob) {
      keep = callback.channel.substr(0, channel.length) !== channel;
    } else {
      keep = callback.channel !== channel;
    }

    const registered =
      metaByWrapper.get(callback.func)?.original ?? callback.func;

    if (!keep && func && registered !== func) {
      keep = true;
    }

    if (!keep) {
      bus.callbacks.splice(i, 1);
      removed = true;
    }
  }

  if (removed && bus.longPoll) {
    bus.longPoll.abort();
  }

  return removed;
}

function instrumentedAjax(this: unknown, options: MessageBusAjaxOptions) {
  if (typeof underlyingAjax !== "function") {
    // Preserve the error MessageBus raises when no adapter is present. The
    // accessor always returns a function, so its own guard can no longer fire.
    throw new Error("Either jQuery or the ajax adapter must be loaded");
  }

  state.polls++;

  // Called through as a method. MessageBus invokes `me.ajax(...)`, so an
  // adapter is entitled to read `this`; calling it bare would silently change
  // that to undefined.
  return underlyingAjax.call(this, decorateForChunks(options));
}

/**
 * Adds a progress listener to the request so chunked responses can be read.
 *
 * Chunked is the usual mode in development, and in that mode MessageBus'
 * `success` handler does nothing at all — messages are delivered through
 * `xhr.onprogress`. Reading only `success` would therefore observe nothing
 * locally.
 *
 * @param options - The options MessageBus passed to `ajax`.
 * @returns The options, with a decorated `xhr` factory.
 */
function decorateForChunks(
  options: MessageBusAjaxOptions
): MessageBusAjaxOptions {
  if (!options?.messageBus?.chunked || typeof options.xhr !== "function") {
    return options;
  }

  const originalXhr = options.xhr;

  return {
    ...options,
    xhr() {
      // jQuery invokes this as `options.xhr()`, and MessageBus' own factory
      // reads `this.messageBus`. Calling it any other way throws under strict
      // mode and takes down every poll, not just this tool.
      // eslint-disable-next-line prefer-rest-params
      const xhr = originalXhr.apply(this, arguments);
      let position = 0;

      // A listener rather than an assignment: MessageBus sets the `onprogress`
      // property, and the two coexist.
      xhr.addEventListener("progress", () => {
        position = readChunks(xhr.responseText, position);
      });

      return xhr;
    },
  };
}

/**
 * Reads whole frames out of a chunked response body.
 *
 * MessageBus' own framing is private to its request, so it is reimplemented
 * here: frames are separated by `\r\n|\r\n`, and a literal separator inside a
 * frame is escaped by doubling the pipe.
 *
 * @param payload - The response body so far.
 * @param position - Where the last complete frame ended.
 * @returns The new cursor position.
 */
function readChunks(payload: string, position: number) {
  const separator = "\r\n|\r\n";

  for (;;) {
    const end = payload.indexOf(separator, position);

    if (end === -1) {
      return position;
    }

    const frame = payload
      .substring(position, end)
      .replace(/\r\n\|\|\r\n/g, separator);

    try {
      for (const message of JSON.parse(frame) as MessageBusFrame[]) {
        recordMessage(message);
      }
    } catch {
      // A frame that does not parse is MessageBus' problem to report; this is
      // only observing.
    }

    position = end + separator.length;
  }
}

function recordMessage(message: MessageBusFrame) {
  state.messages.push({
    channel: message.channel,
    messageId: message.message_id,
    globalId: message.global_id,
    data: message.data,
    receivedAt: Date.now(),
  });

  if (state.messages.length > MAX_MESSAGES) {
    state.messages.splice(0, state.messages.length - MAX_MESSAGES);
  }
}

/**
 * Captures where `subscribe` was called from.
 *
 * @returns A single stack frame, or null if unavailable.
 */
function captureSource() {
  const lines = new Error().stack?.split("\n") ?? [];

  // Frame 0 is the Error, 1 is this function, 2 is instrumentedSubscribe, so
  // the caller is the first frame after those.
  return lines[3]?.trim() ?? null;
}
