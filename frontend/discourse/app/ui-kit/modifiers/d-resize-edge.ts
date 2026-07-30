import { registerDestructor } from "@ember/destroyable";
import type Owner from "@ember/owner";
import { cancel, throttle } from "@ember/runloop";
import Modifier, { type ArgsFor } from "ember-modifier";

const THROTTLE_RATE = 20;

// How far a single arrow key press moves the edge, in pixels.
const KEYBOARD_STEP = 16;

interface DResizeEdgeSignature {
  /** The element acting as the edge. */
  Element: HTMLElement;
  Args: {
    Named: {
      /** The current size, in pixels. */
      value: number;

      /** The smallest size the edge may be dragged to. */
      min: number;

      /** The largest size the edge may be dragged to. */
      max: number;

      /**
       * Which edge the resized element is docked against, in logical terms.
       * Combined with the writing direction this decides whether moving the
       * pointer right makes it larger or smaller. Defaults to `"start"`.
       */
      side?: "start" | "end";

      /**
       * Called continuously while dragging, throttled. Suitable for updating
       * the rendered size.
       */
      onResize?: (size: number) => void;

      /**
       * Called once when the interaction finishes. Suitable for persisting the
       * size.
       */
      onResizeEnd?: (size: number) => void;
    };
    Positional: [];
  };
}

/**
 * Makes an element behave as a draggable edge that resizes something along the
 * horizontal axis, following the WAI-ARIA window splitter pattern.
 *
 * The modifier owns the interaction only. It reports the size it computed and
 * leaves storing and applying it to the caller, so that the same element can
 * drive a width held in a component, a service, or a CSS custom property.
 *
 * Both pointer and keyboard interaction are supported, which is what the
 * splitter pattern requires: a resize that can only be performed by dragging
 * is unusable without a pointing device.
 *
 * ```hbs
 * <div
 *   role="separator"
 *   aria-orientation="vertical"
 *   aria-valuenow={{this.width}}
 *   aria-valuemin={{this.minWidth}}
 *   aria-valuemax={{this.maxWidth}}
 *   tabindex="0"
 *   {{dResizeEdge
 *     value=this.width
 *     min=this.minWidth
 *     max=this.maxWidth
 *     side="start"
 *     onResize=this.previewWidth
 *     onResizeEnd=this.commitWidth
 *   }}
 * ></div>
 * ```
 */
export default class DResizeEdgeModifier extends Modifier<DResizeEdgeSignature> {
  /** The options from the most recent invocation, set by `modify`. */
  declare named: DResizeEdgeSignature["Args"]["Named"];

  #onPointerDown = (event: PointerEvent) => {
    // Ignore anything that is not a primary button press, so that a right
    // click or a secondary pointer cannot begin a resize.
    if (event.button !== 0) {
      return;
    }

    // A drag is already in progress. Taking this one over would overwrite the
    // tracked pointer and strand the first one's capture, since its release
    // would then no longer match.
    if (this.#pointerId !== null) {
      return;
    }

    event.preventDefault();

    this.#pointerId = event.pointerId;
    this.#startCoordinate = event.clientX;
    this.#startValue = this.named.value;

    this.#element.setPointerCapture(event.pointerId);
    this.#element.addEventListener("pointermove", this.#onPointerMove);
    this.#element.addEventListener("pointerup", this.#onPointerUp);
    this.#element.addEventListener("pointercancel", this.#onPointerUp);
  };
  #onPointerMove = (event: PointerEvent) => {
    if (event.pointerId !== this.#pointerId) {
      return;
    }

    // Throttled because a pointer move fires far more often than a size change
    // can usefully be rendered.
    //
    // The cast describes the single-argument call being made: `throttle` reads
    // its interval from the trailing argument, which its overloads cannot
    // express next to `#reportMove`'s optional second parameter.
    this.#throttled = throttle(
      this,
      this.#reportMove as (clientX: number) => void,
      event.clientX,
      THROTTLE_RATE
    );
  };
  #onPointerUp = (event: PointerEvent) => {
    if (event.pointerId !== this.#pointerId) {
      return;
    }

    cancel(this.#throttled);
    this.#reportMove(event.clientX, { final: true });
    this.#releasePointer();
  };
  #onKeyDown = (event: KeyboardEvent) => {
    const { value, min, max } = this.named;
    let next;

    switch (event.key) {
      case "ArrowLeft":
        next = value - KEYBOARD_STEP * this.#growthDirection;
        break;
      case "ArrowRight":
        next = value + KEYBOARD_STEP * this.#growthDirection;
        break;
      case "Home":
        next = min;
        break;
      case "End":
        next = max;
        break;
      default:
        return;
    }

    event.preventDefault();

    const clamped = this.#clamp(next);
    this.named.onResize?.(clamped);
    this.named.onResizeEnd?.(clamped);
  };
  #element: HTMLElement;
  #pointerId: number | null = null;
  #startCoordinate = 0;
  #startValue = 0;
  #throttled?: ReturnType<typeof throttle>;

  constructor(owner: Owner, args: ArgsFor<DResizeEdgeSignature>) {
    super(owner, args);
    registerDestructor(this, (instance) => instance.cleanup());
  }

  modify(
    element: HTMLElement,
    _positional: [],
    named: DResizeEdgeSignature["Args"]["Named"]
  ) {
    this.#element = element;
    this.named = named;

    element.addEventListener("pointerdown", this.#onPointerDown);
    element.addEventListener("keydown", this.#onKeyDown);
  }

  cleanup() {
    cancel(this.#throttled);

    this.#element.removeEventListener("pointerdown", this.#onPointerDown);
    this.#element.removeEventListener("keydown", this.#onKeyDown);
    this.#releasePointer();
  }

  /**
   * The multiplier turning pointer movement into a size change.
   *
   * An element docked to the inline start grows as the pointer moves away from
   * that edge. Which physical direction that is depends on the writing
   * direction, so `side` is interpreted logically and flipped under RTL —
   * otherwise the edge would move away from the pointer dragging it.
   *
   * @returns Either 1 or -1.
   */
  get #growthDirection() {
    const logical = this.named.side === "end" ? -1 : 1;
    const rtl = getComputedStyle(this.#element).direction === "rtl";

    return logical * (rtl ? -1 : 1);
  }

  #reportMove(clientX: number, { final = false }: { final?: boolean } = {}) {
    const delta = (clientX - this.#startCoordinate) * this.#growthDirection;
    const size = this.#clamp(this.#startValue + delta);

    this.named.onResize?.(size);

    if (final) {
      this.named.onResizeEnd?.(size);
    }
  }

  #clamp(size: number) {
    return Math.min(Math.max(size, this.named.min), this.named.max);
  }

  #releasePointer() {
    if (this.#pointerId === null) {
      return;
    }

    if (this.#element.hasPointerCapture(this.#pointerId)) {
      this.#element.releasePointerCapture(this.#pointerId);
    }

    this.#element.removeEventListener("pointermove", this.#onPointerMove);
    this.#element.removeEventListener("pointerup", this.#onPointerUp);
    this.#element.removeEventListener("pointercancel", this.#onPointerUp);
    this.#pointerId = null;
  }
}
