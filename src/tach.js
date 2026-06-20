// Estimated tachometer — an SVG arc gauge. There's no real rpm signal on the
// phone, so the needle is driven by the rpm we compute from road speed and the
// recommended gear (see vehicle.js). It's a 270° sweep with colored zones:
// low/lugging, the green torque-band sweet spot, high, and redline.
//
// Arcs are drawn as sampled polylines rather than SVG arc commands so the
// geometry is trivial to reason about (no large-arc/sweep-flag gotchas).

const NS = "http://www.w3.org/2000/svg";
const D2R = Math.PI / 180;

const DEFAULTS = {
  max: 5000,
  start: 225, // degrees clockwise from top — lower-left (7:30)
  sweep: 270, // ...around to lower-right (4:30), 90° gap at the bottom
  ticks: [0, 1000, 2000, 3000, 4000, 5000],
  torquePeak: 2400,
  zones: [
    { to: 2000, color: "#3b4a5a" }, // low / lugging
    { to: 3600, color: "#34c759" }, // torque-band sweet spot
    { to: 4200, color: "#ffb020" }, // high
    { to: 5000, color: "#ff453a" }, // redline
  ],
};

export function createTachometer(container, opts = {}) {
  const cfg = { ...DEFAULTS, ...opts };
  const { max, start, sweep } = cfg;
  const CX = 100, CY = 100, R = 82, NEEDLE = 70;

  const angle = (v) => start + (Math.max(0, Math.min(max, v)) / max) * sweep;
  const pt = (r, a) => ({ x: CX + r * Math.sin(a * D2R), y: CY - r * Math.cos(a * D2R) });
  const el = (name, attrs) => {
    const n = document.createElementNS(NS, name);
    for (const k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  };
  const arc = (r, a0, a1) => {
    let d = "";
    const step = a1 >= a0 ? 3 : -3;
    for (let a = a0; step > 0 ? a < a1 : a > a1; a += step) {
      const p = pt(r, a);
      d += `${d ? "L" : "M"}${p.x.toFixed(2)} ${p.y.toFixed(2)} `;
    }
    const e = pt(r, a1);
    return `${d}L${e.x.toFixed(2)} ${e.y.toFixed(2)}`;
  };

  const svg = el("svg", { viewBox: "0 0 200 176", class: "tach-svg" });

  // Track + colored zones.
  svg.appendChild(el("path", {
    d: arc(R, start, start + sweep), fill: "none", stroke: "#161e29",
    "stroke-width": 12, "stroke-linecap": "round",
  }));
  let from = 0;
  for (const z of cfg.zones) {
    svg.appendChild(el("path", {
      d: arc(R, angle(from), angle(z.to)), fill: "none", stroke: z.color,
      "stroke-width": 12, "stroke-linecap": "butt", opacity: "0.92",
    }));
    from = z.to;
  }

  // Torque-peak marker.
  {
    const a = angle(cfg.torquePeak);
    const o = pt(R + 7, a), i = pt(R - 7, a);
    svg.appendChild(el("line", { x1: o.x, y1: o.y, x2: i.x, y2: i.y, stroke: "#eafff0", "stroke-width": "2" }));
  }

  // Ticks + labels (×1000).
  for (const v of cfg.ticks) {
    const a = angle(v);
    const o = pt(R - 10, a), i = pt(R - 18, a), lp = pt(R - 30, a);
    svg.appendChild(el("line", { x1: o.x, y1: o.y, x2: i.x, y2: i.y, stroke: "#5d6878", "stroke-width": "2" }));
    const t = el("text", {
      x: lp.x, y: lp.y, fill: "#8a97a8", "font-size": "12", "font-weight": "700",
      "text-anchor": "middle", "dominant-baseline": "central",
    });
    t.textContent = String(v / 1000);
    svg.appendChild(t);
  }

  // Needle (drawn pointing up, rotated to the value) + hub.
  const needle = el("line", {
    x1: CX, y1: CY, x2: CX, y2: CY - NEEDLE, stroke: "#f4f7fb",
    "stroke-width": "3.5", "stroke-linecap": "round",
  });
  svg.appendChild(needle);
  svg.appendChild(el("circle", { cx: CX, cy: CY, r: "7", fill: "#0b0f14", stroke: "#5d6878", "stroke-width": "2" }));

  // Center readout, sitting in the open bottom gap.
  const gearText = el("text", {
    x: CX, y: 130, fill: "#f4f7fb", "font-size": "30", "font-weight": "800", "text-anchor": "middle",
  });
  gearText.textContent = "–";
  const rpmText = el("text", {
    x: CX, y: 154, fill: "#8a97a8", "font-size": "15", "font-weight": "700",
    "text-anchor": "middle", "font-variant-numeric": "tabular-nums",
  });
  rpmText.textContent = "–– rpm";
  svg.appendChild(gearText);
  svg.appendChild(rpmText);

  container.innerHTML = "";
  container.appendChild(svg);

  function update(rpm, info = {}) {
    if (!Number.isFinite(rpm)) {
      needle.setAttribute("transform", `rotate(${start} ${CX} ${CY})`);
      needle.setAttribute("stroke", "#5d6878");
      rpmText.textContent = "–– rpm";
      gearText.textContent = "–";
      return;
    }
    needle.setAttribute("transform", `rotate(${angle(rpm)} ${CX} ${CY})`);
    needle.setAttribute("stroke", rpm >= 4200 ? "#ff453a" : "#f4f7fb");
    rpmText.textContent = `${Math.round(rpm).toLocaleString()} rpm`;
    gearText.textContent = info.gear ?? "–";
    gearText.setAttribute("fill", info.color ?? "#f4f7fb");
  }

  update(NaN);
  return { update };
}
