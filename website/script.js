const header = document.querySelector(".site-header");
const menuButton = document.querySelector(".menu-button");
const toast = document.querySelector(".download-toast");
const mobile = window.matchMedia("(max-width: 700px)");
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

// Mobile navigation
function setMenuOpen(open) {
  header.classList.toggle("open", open);
  menuButton.setAttribute("aria-expanded", String(open));
  menuButton.setAttribute("aria-label", open ? "Close menu" : "Open menu");
}
menuButton.addEventListener("click", () => setMenuOpen(!header.classList.contains("open")));
header.querySelectorAll("nav a").forEach((link) => link.addEventListener("click", () => setMenuOpen(false)));
document.addEventListener("click", (event) => {
  if (!header.contains(event.target)) setMenuOpen(false);
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && header.classList.contains("open")) {
    setMenuOpen(false);
    menuButton.focus();
  }
});
mobile.addEventListener("change", (event) => {
  if (!event.matches) {
    if (document.activeElement === menuButton) header.querySelector("nav a").focus();
    setMenuOpen(false);
  } else if (header.querySelector("nav").contains(document.activeElement)) {
    menuButton.focus();
  }
});

// Download toast
let toastTimer;
document.querySelectorAll("a[download]").forEach((link) => {
  link.addEventListener("click", () => {
    toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove("show"), 5500);
  });
});

// First-launch help opens the matching FAQ
function openLinkedFAQ() {
  if (window.location.hash !== "#launch-faq") return;
  const warning = document.querySelector("#launch-faq");
  if (!warning) return;
  warning.open = true;
  warning.querySelector("summary").focus({ preventScroll: true });
  warning.scrollIntoView({ block: "start" });
}
document.querySelectorAll('a[href="#launch-faq"]').forEach((link) =>
  link.addEventListener("click", () => setTimeout(openLinkedFAQ, 0)),
);
window.addEventListener("hashchange", openLinkedFAQ);
openLinkedFAQ();

// Menu-bar clocks
function updateClocks() {
  const now = new Date();
  const text = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  document.querySelectorAll(".mac-clock").forEach((clock) => {
    clock.textContent = text;
    clock.dateTime = now.toISOString();
  });
}
updateClocks();
setInterval(updateClocks, 15000);
document.addEventListener("visibilitychange", updateClocks);

// The desk demo mirrors the real app: the sender only transmits while ⌘ is
// held and the cursor is within an edge margin; the receiver only draws while
// its own ⌘ is held. Nothing here touches the network.
const desk = document.querySelector(".desk");
const senderCanvas = document.querySelector("#sender-canvas");
const senderCursor = document.querySelector("#sender-cursor");
const ghost = document.querySelector("#receiver-ghost");
const readout = document.querySelector("#link-readout");
const linkLabel = document.querySelector("#link-label");
const caption = document.querySelector("#demo-caption");
const status = document.querySelector("#demo-status");
const senderHint = document.querySelector("#sender-hint");
const receiverHint = document.querySelector("#receiver-hint");
const toggles = document.querySelectorAll(".consent-toggle[data-side]");
const playButton = document.querySelector("#demo-play");

const EDGE_MARGIN = 0.1; // fraction of the screen; the app uses 24 px
const consent = { sender: false, receiver: false };
const position = { x: 0.28, y: 0.44 };
let realKeyHeld = false;
let fadeTimer;
let link = "idle";
let playing = false;
let playAnimation;

function announce(message) {
  caption.textContent = message;
  status.textContent = message;
}

function nearEdge() {
  return (
    position.x <= EDGE_MARGIN ||
    position.x >= 1 - EDGE_MARGIN ||
    position.y <= EDGE_MARGIN ||
    position.y >= 1 - EDGE_MARGIN
  );
}

function setLink(next) {
  if (link === next) return;
  link = next;
  desk.dataset.link = next;
}

function paintPointer() {
  senderCursor.style.left = `${position.x * 100}%`;
  senderCursor.style.top = `${position.y * 100}%`;
  readout.textContent = `x ${position.x.toFixed(2)} · y ${position.y.toFixed(2)}`;
  if (link === "sending") {
    ghost.style.left = `${position.x * 100}%`;
    ghost.style.top = `${position.y * 100}%`;
  }
}

function evaluate() {
  clearTimeout(fadeTimer);
  const edge = nearEdge();
  const sending = consent.sender && edge;
  const shown = sending && consent.receiver;

  if (shown) {
    setLink("sending");
    linkLabel.textContent = "UDP · packet in flight";
    receiverHint.textContent = "Pointer ghost at the matching spot";
    senderHint.innerHTML = "Sending position";
    announce("Sending. The receiver shows the ghost at the same proportional spot.");
    paintPointer();
    return;
  }

  // The real receiver keeps the last packet grey for ~0.45 s after it stops.
  if (link === "sending") {
    setLink("fading");
    fadeTimer = setTimeout(() => setLink(consent.sender && edge ? "edge" : "idle"), 450);
  } else {
    setLink(sending ? "edge" : consent.sender && edge ? "edge" : "idle");
  }

  linkLabel.textContent = "UDP · local network";

  if (!consent.sender && !consent.receiver) {
    senderHint.innerHTML = "Hold <kbd>⌘</kbd> and move toward an edge";
    receiverHint.textContent = "Waiting for a pointer";
    announce("Both Macs are idle. Hold ⌘ on each to begin.");
  } else if (consent.sender && !consent.receiver) {
    senderHint.innerHTML = edge ? "At the edge, but the receiver hasn’t agreed" : "Move toward an edge to send";
    receiverHint.innerHTML = "Hold <kbd>⌘</kbd> here to allow the overlay";
    announce(edge ? "Sender is at the edge. The receiver has not consented, so nothing is shown." : "Sender ready. Move the cursor to an edge to send.");
  } else if (!consent.sender && consent.receiver) {
    senderHint.innerHTML = "Hold <kbd>⌘</kbd> here to share position";
    receiverHint.textContent = "Listening. Nothing arriving yet.";
    announce("Receiver is listening. The sender has not consented, so nothing is sent.");
  } else {
    senderHint.textContent = "Both agreed. Move toward an edge.";
    receiverHint.textContent = "Ready for the ghost";
    announce("Both Macs consent. Move the sender cursor toward an edge.");
  }
  paintPointer();
}

function setConsent(side, held) {
  consent[side] = held;
  desk.dataset[side] = held ? "held" : "released";
  document.querySelector(`#${side}-pill`).textContent = held ? "⌘ held" : "⌘ released";
  toggles.forEach((button) => {
    if (button.dataset.side === side) button.setAttribute("aria-pressed", String(held));
  });
  evaluate();
}

toggles.forEach((button) =>
  button.addEventListener("click", () => {
    stopPlayback();
    setConsent(button.dataset.side, button.getAttribute("aria-pressed") !== "true");
  }),
);

function updateFromPointer(event) {
  const rect = senderCanvas.getBoundingClientRect();
  position.x = Math.min(Math.max((event.clientX - rect.left) / rect.width, 0), 1);
  position.y = Math.min(Math.max((event.clientY - rect.top) / rect.height, 0), 1);
  evaluate();
}
senderCanvas.addEventListener("pointermove", (event) => {
  if (playing) return;
  if (event.pointerType === "touch" && !event.buttons) return;
  updateFromPointer(event);
});
senderCanvas.addEventListener("pointerdown", (event) => {
  if (playing) return;
  senderCanvas.setPointerCapture(event.pointerId);
  updateFromPointer(event);
});

// The real ⌘ key stands in for both sides at once, like holding it on two Macs.
window.addEventListener("keydown", (event) => {
  if (event.key !== "Meta" || event.repeat || realKeyHeld) return;
  realKeyHeld = true;
  stopPlayback();
  setConsent("sender", true);
  setConsent("receiver", true);
});
window.addEventListener("keyup", (event) => {
  if (event.key !== "Meta" || !realKeyHeld) return;
  realKeyHeld = false;
  setConsent("sender", false);
  setConsent("receiver", false);
});
window.addEventListener("blur", () => {
  if (!realKeyHeld) return;
  realKeyHeld = false;
  setConsent("sender", false);
  setConsent("receiver", false);
});

// Scripted walkthrough: consent on both sides, glide to the edge, release.
function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, reducedMotion.matches ? Math.min(ms, 250) : ms));
}
function glide(toX, toY, ms) {
  return new Promise((resolve) => {
    if (reducedMotion.matches) {
      position.x = toX;
      position.y = toY;
      evaluate();
      resolve();
      return;
    }
    const fromX = position.x;
    const fromY = position.y;
    const start = performance.now();
    const step = (now) => {
      if (!playing) return resolve();
      const t = Math.min((now - start) / ms, 1);
      const ease = 1 - Math.pow(1 - t, 3);
      position.x = fromX + (toX - fromX) * ease;
      position.y = fromY + (toY - fromY) * ease;
      evaluate();
      if (t < 1) playAnimation = requestAnimationFrame(step);
      else resolve();
    };
    playAnimation = requestAnimationFrame(step);
  });
}
function stopPlayback() {
  if (!playing) return;
  playing = false;
  cancelAnimationFrame(playAnimation);
  playButton.disabled = false;
  playButton.querySelector("span").textContent = "Play the whole thing";
}
async function play() {
  if (playing) return;
  playing = true;
  playButton.disabled = true;
  playButton.querySelector("span").textContent = "Playing…";
  setConsent("sender", false);
  setConsent("receiver", false);
  position.x = 0.3;
  position.y = 0.45;
  evaluate();
  await wait(500);
  if (!playing) return;
  setConsent("sender", true);
  await wait(650);
  if (!playing) return;
  setConsent("receiver", true);
  await wait(650);
  if (!playing) return;
  await glide(0.96, 0.4, 1400);
  await wait(400);
  if (!playing) return;
  await glide(0.97, 0.7, 900);
  await wait(900);
  if (!playing) return;
  setConsent("receiver", false);
  await wait(800);
  if (!playing) return;
  setConsent("sender", false);
  await glide(0.5, 0.5, 700);
  stopPlayback();
}
playButton.addEventListener("click", play);
evaluate();

// Optional enhancement: vendored MIT Rough Notation for drawn accents.
async function setupAnnotations() {
  try {
    const { annotate } = await import("./assets/vendor/rough-notation-0.5.1.esm.js");
    await document.fonts.ready;
    const annotations = [];
    const elements = document.querySelectorAll(".drawn-underline, .drawn-circle");
    const observer =
      "IntersectionObserver" in window
        ? new IntersectionObserver(
            (entries) => {
              entries.forEach((entry) => {
                if (!entry.isIntersecting) return;
                const item = annotations.find((item) => item.element === entry.target);
                if (item) item.annotation.show();
                observer.unobserve(entry.target);
              });
            },
            { threshold: 0.8 },
          )
        : null;
    elements.forEach((element) => {
      const circle = element.classList.contains("drawn-circle");
      const annotation = annotate(element, {
        type: circle ? "circle" : "underline",
        color: circle ? "#3f7f9e" : "#d99872",
        strokeWidth: 2,
        padding: circle ? 5 : 4,
        iterations: 2,
        animationDuration: 650,
        animate: !reducedMotion.matches,
      });
      annotations.push({ element, annotation });
      if (circle) {
        element.addEventListener("pointerenter", (event) => {
          if (event.pointerType === "touch" || reducedMotion.matches) return;
          annotation.hide();
          annotation.show();
        });
      }
      if (observer) observer.observe(element);
      else annotation.show();
    });
    document.documentElement.classList.add("annotations-ready");
    reducedMotion.addEventListener("change", () => {
      annotations.forEach(({ annotation }) => {
        const showing = annotation.isShowing();
        annotation.hide();
        annotation.animate = !reducedMotion.matches;
        if (showing) annotation.show();
      });
    });
    document.querySelectorAll(".rough-annotation").forEach((svg) => svg.setAttribute("aria-hidden", "true"));
  } catch {
    // The CSS underline remains a functional, static fallback.
  }
}
setupAnnotations();

// Key caps lean gently toward the pointer.
const consentArt = document.querySelector(".consent-art");
const keycaps = document.querySelectorAll(".keycap");
const finePointer = window.matchMedia("(hover: hover) and (pointer: fine)");
let capFrame;
function resetKeycaps() {
  cancelAnimationFrame(capFrame);
  keycaps.forEach((cap) => {
    cap.style.removeProperty("--card-x");
    cap.style.removeProperty("--card-y");
  });
}
consentArt.addEventListener("pointermove", (event) => {
  if (reducedMotion.matches || !finePointer.matches || event.pointerType === "touch") return;
  const bounds = consentArt.getBoundingClientRect();
  const x = Math.max(-1, Math.min(1, ((event.clientX - bounds.left) / bounds.width) * 2 - 1));
  const y = Math.max(-1, Math.min(1, ((event.clientY - bounds.top) / bounds.height) * 2 - 1));
  cancelAnimationFrame(capFrame);
  capFrame = requestAnimationFrame(() => {
    keycaps.forEach((cap, index) => {
      const depth = index ? 5 : 8;
      cap.style.setProperty("--card-x", `${x * depth}px`);
      cap.style.setProperty("--card-y", `${y * (depth - 2)}px`);
    });
  });
});
consentArt.addEventListener("pointerleave", resetKeycaps);
consentArt.addEventListener("pointercancel", resetKeycaps);
reducedMotion.addEventListener("change", resetKeycaps);
finePointer.addEventListener("change", resetKeycaps);
