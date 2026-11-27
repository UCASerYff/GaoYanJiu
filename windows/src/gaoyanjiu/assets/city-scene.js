(function () {
"use strict";

const terrainColors = {
  lake: "#74b9d0", forest: "#72934d", desert: "#dbb477", snowMountain: "#cbdce6",
  wetland: "#6c9984", volcanic: "#62534e", flowerMeadow: "#92b871", crystalField: "#88a8b5",
};
const wallColors = ["#eee1c9", "#c68a69", "#e0bd79", "#ead6ab", "#f1e6d1", "#426b82"];
const roofColors = ["#344d49", "#4e5b72", "#c39851", "#159caa", "#3c444c", "#23394f"];
const trimColors = ["#973d2c", "#f3dbb0", "#287f94", "#346a9a", "#604231", "#58dadd"];
const rareColors = ["#c2bca9", "#9ebaa3", "#b8a5cb", "#dcb878", "#c78496"];
const degrees = Math.PI / 180;
const splitID = (id) => id.split(":").map(Number);
const plotForCell = (row, column) => [Math.floor(row / 3), Math.floor(column / 3)].join(":");
const dimensions = (asset, rotation) => rotation % 2 ? [asset.depth, asset.width] : [asset.width, asset.depth];
const worldFace = (points, color, extra) => ({points, color, ...extra});

function shade(hex, amount) {
  const color = parseInt(hex.slice(1), 16);
  const part = (shift) => Math.round(Math.min(255, ((color >> shift) & 255) * amount));
  return "rgb(" + [part(16), part(8), part(0)].join(",") + ")";
}

function finishColor(hex, variant) {
  const value = parseInt(hex.slice(1), 16);
  const component = (shift, offset) => Math.max(0, Math.min(255, ((value >> shift) & 255) + offset))
    .toString(16).padStart(2, "0");
  const difference = (variant - 3) * 4;
  return "#" + component(16, difference) + component(8, Math.round(difference * 0.5)) + component(0, -difference);
}

class Mesh {
  constructor() { this.faces = []; }

  face(points, color, texture) {
    const [a, b, c] = points;
    const u = b.map((value, index) => value - a[index]);
    const v = c.map((value, index) => value - a[index]);
    const normal = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2], u[0] * v[1] - u[1] * v[0]];
    const size = Math.hypot(...normal) || 1;
    const light = 0.75 + (normal[0] * -0.16 + normal[1] * 0.25 + normal[2] * 0.12) / size;
    this.faces.push(worldFace(points, shade(color, light), {texture}));
  }

  box(x, y, z, width, height, depth, color) {
    const x0 = x - width / 2, x1 = x + width / 2, z0 = z - depth / 2, z1 = z + depth / 2, y1 = y + height;
    const a = [x0, y, z0], b = [x1, y, z0], c = [x1, y, z1], d = [x0, y, z1];
    const e = [x0, y1, z0], f = [x1, y1, z0], g = [x1, y1, z1], h = [x0, y1, z1];
    for (const ends of [[h, g, f, e], [a, b, c, d], [b, a, e, f], [c, b, f, g], [d, c, g, h], [a, d, h, e]]) {
      this.face(ends, color);
    }
  }

  round(x, y, z, radius, height, color, topRadius = radius, sides = 12) {
    const lower = [], upper = [];
    for (let index = 0; index < sides; index++) {
      const angle = -Math.PI * 2 * index / sides;
      lower.push([x + Math.cos(angle) * radius, y, z + Math.sin(angle) * radius]);
      upper.push([x + Math.cos(angle) * topRadius, y + height, z + Math.sin(angle) * topRadius]);
    }
    for (let index = 0; index < sides; index++) {
      const after = (index + 1) % sides;
      this.face([lower[index], lower[after], upper[after], upper[index]], color);
    }
    if (topRadius > 0) this.face(upper, color);
  }

  ball(x, y, z, radius, color) {
    this.round(x, y - radius, z, 0, radius, color, radius, 8);
    this.round(x, y, z, radius, radius, color, 0, 8);
  }

  beam(p, q, width, color) {
    const angle = Math.atan2(q[0] - p[0], q[2] - p[2]);
    const a = Math.cos(angle) * width / 2, b = -Math.sin(angle) * width / 2;
    this.face([[p[0] - a, p[1], p[2] - b], [q[0] - a, q[1], q[2] - b], [q[0] + a, q[1], q[2] + b], [p[0] + a, p[1], p[2] + b]], color);
    this.face([[p[0], p[1] + width, p[2]], [q[0], q[1] + width, q[2]], [q[0], q[1], q[2]], [p[0], p[1], p[2]]], color);
  }

  roof(x, y, z, width, depth, height, roof, trim, curved = false) {
    const front = z + depth / 2, back = z - depth / 2;
    const ridgeFront = [x, y + height, front], ridgeBack = [x, y + height, back];
    for (const sign of [-1, 1]) {
      const edgeX = x + sign * width / 2;
      const edgeY = y + (curved ? height * 0.30 : 0);
      const points = [[edgeX, edgeY, front], [edgeX, edgeY, back], ridgeBack, ridgeFront];
      this.face(sign > 0 ? points : points.slice().reverse(), roof);
      this.beam(points[0], points[1], 0.038, trim);
      if (curved) this.beam(points[0], [edgeX + sign * 0.04, edgeY + 0.06, front], 0.05, trim);
    }
    this.face([[x - width / 2, y, front], [x + width / 2, y, front], ridgeFront], trim);
    this.face([[x + width / 2, y, back], [x - width / 2, y, back], ridgeBack], trim);
    this.beam(ridgeBack, ridgeFront, 0.028, trim);
  }
}

function buildingShell(mesh, style, width, depth, height, wall, roof, trim) {
  mesh.box(0, 0.07, 0, width, height, depth, wall);
  mesh.box(0, 0.07, 0, width + 0.06, 0.08, depth + 0.06, trim);
  const front = depth / 2;
  for (let y = 0.27; y < height - 0.03; y += 0.26) {
    for (const x of [-width * 0.30, width * 0.30]) {
      mesh.box(x, y, front + 0.008, 0.151, 0.155, 0.022, trim);
      mesh.box(x, y + 0.015, front + 0.021, 0.119, 0.128, 0.013, "#9ec0cb");
      mesh.box(x, y + 0.014, front + 0.03, 0.011, 0.131, 0.016, trim);
    }
    for (const z of [-depth * 0.26, depth * 0.26]) {
      for (const side of [-1, 1]) {
        mesh.box(side * (width / 2 + 0.008), y, z, 0.025, 0.15, 0.142, trim);
        mesh.box(side * (width / 2 + 0.023), y + 0.013, z, 0.016, 0.125, 0.111, "#9ec0cb");
      }
    }
  }
  mesh.box(0, 0.13, front + 0.032, 0.20, 0.26, 0.035, "#634b34");
  for (let index = 0; index < 3; index++) {
    mesh.box(0, 0.06, front + (index + 0.6) * 0.046, 0.30 + index * 0.075, 0.065 - index * 0.02, 0.07, "#cdc2a4");
  }
  const y = height + 0.07;
  if ([0, 1, 4].includes(style)) {
    mesh.roof(0, y, 0, width + 0.20, depth + 0.18, 0.25, roof, trim, style !== 1);
    if (style === 1) mesh.box(width * 0.28, y + 0.12, -depth * 0.19, 0.11, 0.23, 0.12, wall);
    else for (const x of [-width * 0.45, width * 0.45]) mesh.round(x, 0.13, front + 0.04, 0.024, height - 0.05, trim);
  } else if (style === 2) {
    mesh.box(0, y, 0, width + 0.06, 0.1, depth + 0.06, roof);
    mesh.round(0, y + 0.10, 0, Math.min(width, depth) * 0.41, 0.33, roof, 0.035, 4);
    for (const x of [-width * 0.4, width * 0.4]) mesh.round(x, 0.13, front + 0.065, 0.041, height - 0.04, trim);
  } else if (style === 3) {
    mesh.box(0, y, 0, width + 0.07, 0.06, depth + 0.07, trim);
    mesh.round(0, y + 0.045, 0, 0.25, 0.1, wall);
    mesh.ball(0, y + 0.25, 0, 0.26, roof);
    mesh.round(0, y + 0.47, 0, 0.012, 0.12, "#d7b16c");
  } else {
    mesh.box(0, y, 0, width + 0.09, 0.06, depth + 0.09, trim);
    for (let level = 0.22; level < height; level += 0.18) mesh.box(0, level, 0, width + 0.03, 0.025, depth + 0.03, trim);
    mesh.round(0, y + 0.05, 0, 0.012, 0.28, trim);
  }
}

function buildingMesh(mesh, asset, wall, roof, trim) {
  const use = asset.architectureUse, style = asset.architectureStyle;
  if (use === 4) {
    buildingShell(mesh, style, 0.72, 0.64, 0.96, wall, roof, trim);
    for (const x of [-0.45, 0.45]) for (const z of [-0.40, 0.40]) {
      mesh.round(x, 0.07, z, 0.13, 0.94, wall);
      mesh.round(x, 1.00, z, 0.17, 0.29, roof, 0, 8);
    }
    mesh.box(0, 0.06, 0.46, 0.99, 0.27, 0.1, wall);
    for (let x = -0.44; x <= 0.45; x += 0.147) mesh.box(x, 0.33, 0.46, 0.07, 0.09, 0.13, wall);
    return;
  }
  if (use === 5) {
    const center = [0, 0.64, 0], points = Array.from({length: 16}, (_, index) => {
      const angle = index * Math.PI / 8;
      return [0.43 * Math.cos(angle), center[1] + 0.43 * Math.sin(angle), 0];
    });
    for (const [index, point] of points.entries()) {
      mesh.beam(point, points[(index + 1) % points.length], 0.029, trim);
      if (index % 2 === 0) {
        mesh.beam(center, point, 0.015, roof);
        mesh.box(point[0], point[1] - 0.05, 0.01, 0.1, 0.078, 0.1, ["#eab365", "#6fb69e", trim][index % 3]);
      }
    }
    for (const x of [-0.24, 0.24]) mesh.beam([x, 0.08, 0.17], center, 0.05, roof);
    mesh.round(0.33, 0.08, 0.38, 0.17, 0.07, trim);
    mesh.round(0.33, 0.37, 0.38, 0.20, 0.18, roof, 0);
    return;
  }
  if (use === 6) {
    for (const x of [-0.30, 0.30]) for (const z of [-0.25, 0.25]) {
      mesh.box(x, 0.08, z, 0.43, 0.18, 0.34, wall);
      for (const side of [-1, 1]) mesh.round(x + side * 0.18, 0.24, z - 0.13, 0.017, 0.29, roof);
      for (let stripe = -2; stripe <= 2; stripe++) mesh.box(x + stripe * 0.085, 0.50, z, 0.086, 0.035, 0.40, stripe % 2 ? trim : "#f1d9aa");
      for (let item = -1; item <= 1; item++) mesh.ball(x + item * 0.11, 0.29, z + 0.07, 0.044, ["#cd6542", "#d8ad42", "#75a35e"][item + 1]);
    }
    return;
  }
  const height = use === 3 ? 1.28 : (use === 8 && style === 5 ? 1.56 : 0.78);
  buildingShell(mesh, style, use === 7 ? 1 : 0.85, 0.72, height, wall, roof, trim);
  if (use === 0) {
    for (let index = -4; index < 4; index++) mesh.box(index * 0.09 + 0.045, 0.52, 0.48, 0.091, 0.032, 0.19, index % 2 ? trim : "#ffeaca");
    mesh.round(-0.36, 0.22, 0.60, 0.105, 0.027, wall);
    mesh.round(-0.36, 0.07, 0.60, 0.023, 0.16, trim);
  } else if (use === 1 || use === 2 || use === 7) {
    mesh.box(0, 0.54, 0.44, 0.91, 0.065, 0.23, trim);
    if (use === 1) {
      for (let x = -0.39; x <= 0.4; x += 0.1) mesh.ball(x, 0.56, 0.56, 0.021, "#ffd580");
    } else for (const x of [-0.36, -0.12, 0.12, 0.36]) mesh.round(x, 0.11, 0.51, 0.021, 0.43, trim);
  } else if (use === 3) {
    for (const y of [0.55, 0.84, 1.14]) mesh.box(0, y, 0.43, 0.65, 0.027, 0.19, trim);
  } else if (use === 9) {
    mesh.round(0, 0.98, -0.12, 0.275, 0.10, trim);
    mesh.ball(0, 1.19, -0.12, 0.26, "#c3d1d4");
    mesh.beam([0, 1.19, -0.12], [0.31, 1.52, 0.05], 0.105, roof);
  }
}

function decorationMesh(mesh, index, wall, roof, trim) {
  if (index === 0) {
    for (const z of [-0.11, -0.034, 0.043, 0.12]) mesh.box(0, 0.24, z, 0.65, 0.027, 0.063, "#967148");
    for (const y of [0.35, 0.43]) mesh.box(0, y, -0.15, 0.65, 0.05, 0.035, "#967148");
    for (const x of [-0.25, 0.25]) mesh.box(x, 0.061, 0, 0.036, 0.20, 0.28, trim);
  } else if (index === 1 || index === 7) {
    for (const x of [-0.27, 0.27]) mesh.round(x, 0.05, 0, 0.046, 0.70, "#a53b29");
    mesh.box(0, 0.70, 0, 0.75, 0.06, 0.12, "#a53b29");
    mesh.box(0, 0.58, 0, 0.64, 0.043, 0.08, "#a53b29");
    if (index === 1) {
      mesh.roof(0, 0.75, 0, 0.88, 0.27, 0.11, roof, trim, true);
      for (const x of [-0.20, 0.20]) mesh.ball(x, 0.52, 0, 0.061, "#dc623a");
    }
  } else if (index === 2) {
    for (const [radius, y] of [[0.34, 0.06], [0.23, 0.29], [0.13, 0.51]]) {
      mesh.round(0, y, 0, radius, 0.055, wall);
      mesh.round(0, y + 0.055, 0, radius * 0.86, 0.016, "#65b4c7");
    }
    mesh.round(0, 0.08, 0, 0.045, 0.50, trim);
    mesh.ball(0, 0.62, 0, 0.043, "#a4d6da");
  } else if (index === 3) {
    mesh.box(0, 0.13, 0, 0.51, 0.16, 0.34, "#a87449");
    for (const x of [-0.22, 0.22]) mesh.box(x, 0.05, 0, 0.085, 0.11, 0.38, trim);
    for (let row = -1; row <= 1; row++) for (let col = -1; col <= 1; col++) {
      const x = col * 0.13, z = row * 0.09;
      mesh.round(x, 0.27, z, 0.018, 0.11, "#68965c");
      mesh.ball(x, 0.38, z, 0.047, ["#e7a1a9", "#e6c065", "#a99aca"][col + 1]);
    }
  } else if (index === 4) {
    mesh.box(0, 0.07, 0, 0.32, 0.60, 0.30, wall);
    mesh.roof(0, 0.67, 0, 0.44, 0.39, 0.16, roof, trim);
    mesh.box(0, 0.46, 0.158, 0.18, 0.17, 0.02, "#ffe8ad");
    mesh.box(0, 0.51, 0.172, 0.018, 0.078, 0.017, trim);
    mesh.box(0.02, 0.51, 0.172, 0.058, 0.012, 0.017, trim);
  } else if (index === 5) {
    mesh.box(0, 0.07, 0, 0.27, 0.21, 0.27, wall);
    for (const tilt of [0, Math.PI / 4, -Math.PI / 4]) {
      const ring = Array.from({length: 12}, (_, side) => {
        const angle = side * Math.PI / 6;
        return [0.22 * Math.cos(angle), 0.49 + 0.22 * Math.sin(angle) * Math.cos(tilt), 0.22 * Math.sin(angle) * Math.sin(tilt)];
      });
      ring.forEach((point, side) => mesh.beam(point, ring[(side + 1) % ring.length], 0.026, "#c49b52"));
    }
  } else if (index === 6 || index === 9) {
    const color = index === 6 ? "#679249" : "#9c774a";
    for (let offset = -1; offset <= 1; offset++) {
      const height = 0.53 + offset * 0.095, x = offset * 0.16;
      mesh.round(x, 0.06, -0.03, 0.024, height, color);
      for (const sign of [-1, 1]) mesh.beam([x, height, -0.03], [x + 0.13 * sign, height - 0.063, 0.09], 0.066, "#608957");
      mesh.ball(x, height + 0.04, -0.03, 0.08, "#608957");
    }
  } else if (index === 8) {
    mesh.box(0, 0.06, 0, 0.26, 0.14, 0.26, wall);
    mesh.box(0, 0.19, 0, 0.13, 0.55, 0.13, wall);
    mesh.round(0, 0.74, 0, 0.09, 0.15, "#d5b46b", 0, 4);
  } else if (index === 10) {
    mesh.round(0, 0.05, 0, 0.035, 0.64, trim);
    for (const x of [-0.17, 0.17]) {
      mesh.beam([0, 0.64, 0], [x, 0.66, 0], 0.027, trim);
      mesh.ball(x, 0.62, 0, 0.056, "#f7d893");
    }
  } else {
    mesh.box(0, 0.06, 0, 0.54, 0.31, 0.27, wall);
    mesh.roof(0, 0.40, 0, 0.64, 0.35, 0.10, "#3d677f", "#6abcb2");
    mesh.round(0.24, 0.40, -0.12, 0.014, 0.28, trim);
  }
}

const models = new Map();
function model(asset) {
  const cached = models.get(asset.id);
  if (cached) return cached;
  const mesh = new Mesh();
  const variant = asset.finishVariant;
  const color = (items) => finishColor(items[asset.architectureStyle], variant);
  const [wall, roof, trim] = [wallColors, roofColors, trimColors].map(color);
  const scale = Math.min(asset.width, asset.depth) * 0.82;
  const level = ["common", "rare", "epic", "legendary", "mythic"].indexOf(asset.rarity);
  mesh.box(0, 0.01, 0, asset.width * 0.90 / scale, 0.048, asset.depth * 0.90 / scale, rareColors[level]);
  if (asset.kind === "building") buildingMesh(mesh, asset, wall, roof, trim);
  else decorationMesh(mesh, (asset.sequence - 1) % 12, wall, roof, trim);
  const geometry = {faces: mesh.faces, scale};
  if (models.size >= 128) models.delete(models.keys().next().value);
  models.set(asset.id, geometry);
  return geometry;
}

function addModel(faces, asset, row, column, rotation, extra) {
  const [width, depth] = dimensions(asset, rotation);
  const originX = column + width / 2, originZ = row + depth / 2;
  const {faces: parts, scale} = model(asset);
  const sine = Math.sin(rotation * Math.PI / 2), cosine = Math.cos(rotation * Math.PI / 2);
  for (const face of parts) {
    const points = face.points.map(([x, y, z]) => [
      originX + (x * cosine - z * sine) * scale, y * scale, originZ + (x * sine + z * cosine) * scale,
    ]);
    faces.push({...face, points, ...extra});
  }
}

function coordinates(x, z, width, depth, y = 0) {
  return [[x, y, z], [x + width, y, z], [x + width, y, z + depth], [x, y, z + depth]];
}

function nearestAnchor(asset, row, column, rotation) {
  const [width, depth] = dimensions(asset, rotation);
  const plotRow = Math.floor(row / 3) * 3, plotColumn = Math.floor(column / 3) * 3;
  return [Math.min(row, plotRow + 3 - depth), Math.min(column, plotColumn + 3 - width)];
}

function boardBounds(plots) {
  const rows = plots.map(({id}) => splitID(id)[0]);
  const columns = plots.map(({id}) => splitID(id)[1]);
  const firstRow = Math.min(...rows, ...(plots.length ? [] : [2]));
  const lastRow = Math.max(...rows, ...(plots.length ? [] : [4]));
  const firstCol = Math.min(...columns, ...(plots.length ? [] : [2]));
  const lastCol = Math.max(...columns, ...(plots.length ? [] : [4]));
  const width = (lastCol - firstCol + 1) * 3 + 3.2;
  const depth = (lastRow - firstRow + 1) * 3 + 3.2;
  return {
    x: (firstCol + lastCol + 1) * 1.5, z: (firstRow + lastRow + 1) * 1.5, width, depth,
    drop: Math.min(30, Math.max(8, Math.sqrt(width * depth) * 0.56)),
  };
}

function islandGeometry(bounds, faces, waterfalls) {
  const {x, z, width, depth, drop} = bounds;
  const outline = Array.from({length: 72}, (_, index) => {
    const angle = index * Math.PI / 36;
    const dx = Math.cos(angle), dz = Math.sin(angle);
    let lower = 0, upper = Math.hypot(width, depth) / 2;
    for (let step = 0; step < 14; step++) {
      const middle = (lower + upper) / 2;
      const cornerX = Math.max(0, Math.abs(dx * middle) - width / 2 + 1.4);
      const cornerZ = Math.max(0, Math.abs(dz * middle) - depth / 2 + 1.4);
      if (Math.hypot(cornerX, cornerZ) > 1.4) upper = middle;
      else lower = middle;
    }
    const radius = lower + 0.13 + 0.12 * Math.sin(angle * 11) * Math.cos(angle * 7);
    return [dx * radius, dz * radius, angle];
  });
  const scale = [1, 1.008, 0.97, 0.83, 0.38, 0.015];
  const heights = [-0.11, -0.63, -2.2, -drop * 0.60, -drop * 0.88, -drop - 0.9];
  const cliff = ["#66805a", "#778682", "#71817e", "#637474", "#536160"];
  const ringPoint = (index, level) => {
    const [dx, dz, angle] = outline[index % outline.length];
    const irregular = level <= 1 ? 1 : 1 + 0.045 * Math.sin(angle * 9 + level) + 0.025 * Math.cos(angle * 17);
    const y = heights[level] + (level <= 1 ? 0 : 0.35 * Math.sin(angle * 7 + level));
    return [x + dx * scale[level] * irregular, y, z + dz * scale[level] * irregular];
  };
  for (const [index, [, , angle]] of outline.entries()) {
    faces.push(worldFace([[x, -0.11, z], ringPoint(index, 0), ringPoint(index + 1, 0)], "#779950", {texture: "grass"}));
    for (let level = 0; level < heights.length - 1; level++) {
      const points = [ringPoint(index, level), ringPoint(index + 1, level), ringPoint(index + 1, level + 1), ringPoint(index, level + 1)];
      const tint = 0.85 + Math.cos(angle - 1.1) * 0.13 + Math.sin(index * 7) * 0.04;
      faces.push(worldFace(points, shade(cliff[level], tint), {texture: "rock"}));
    }
  }
  const roots = new Mesh();
  for (let index = 0; index < outline.length; index += 5) {
    const [dx, dz] = outline[index];
    const height = 1.6 + index % 4 * 0.42;
    roots.round(x + dx * 0.92, -height - 0.4, z + dz * 0.92, 0.06, height, "#678078", 0.4, 7);
    if (index % 3 === 0) {
      for (let leaf = 0; leaf < 4; leaf++) {
        roots.ball(x + dx * (1 - leaf * 0.011), -0.32 - leaf * 0.24,
          z + dz * (1 - leaf * 0.011), 0.15 - leaf * 0.011, "#5d874d");
      }
    }
  }
  faces.push(...roots.faces);
  for (const index of [9, 45]) {
    const [dx, dz] = outline[index];
    const length = Math.hypot(dx, dz);
    const unitX = -dz / length, unitZ = dx / length;
    const point = (distance, stripe) => {
      const radius = 1.003 + distance * 0.075;
      const side = stripe * (1 - distance * 0.4);
      return [x + dx * radius + unitX * side, -0.105 - distance * drop * 0.82, z + dz * radius + unitZ * side];
    };
    const strips = [];
    for (let row = 0; row < 10; row++) for (let column = 0; column < 7; column++) {
      const start = row / 10, end = (row + 1.005) / 10;
      const left = (column - 3.5) * 0.136, right = left + 0.137;
      const opacity = (0.60 - start * 0.48) * (0.82 + Math.sin(column * 4 + row) * 0.17);
      strips.push(worldFace([point(start, left), point(start, right), point(end, right), point(end, left)],
        "rgba(171,229,241," + opacity + ")"));
    }
    waterfalls.push({direction: [dx, dz], strips});
  }
}

function terrainMesh(kind, variant, row, column) {
  const mesh = new Mesh(), x = column * 3, z = row * 3;
  for (let index = 0; index < 6; index++) {
    const n = (variant + 1) * 17 + index * 7;
    const tx = x + 0.30 + ((n * 23) % 23 + index * 0.39) % 2.4;
    const tz = z + 0.35 + ((n * 13) % 29) / 29 * 2.25;
    if (kind === "forest" || kind === "wetland") {
      const height = kind === "forest" ? 0.85 + n % 5 * 0.13 : 0.24;
      mesh.round(tx, 0.03, tz, 0.055, height * 0.65, "#785a39", 0.03, 7);
      mesh.round(tx, height * 0.29, tz, height * 0.30, height * 0.79, index % 2 ? "#648f4b" : "#507c43", 0, 8);
    } else if (kind === "snowMountain" || kind === "volcanic") {
      const size = index % 3 * 0.17 + 0.29;
      const rose = 0.29 + size * 1.6;
      mesh.round(tx, 0.02, tz, size, rose, kind === "snowMountain" ? "#849eaf" : "#624b43", size * 0.15, 7);
      mesh.round(tx, rose + 0.019, tz, size * 0.15, size * 0.33, kind === "snowMountain" ? "#f1f2f0" : "#bb6747", 0, 7);
    } else if (kind === "crystalField") {
      const rose = 0.19 + index % 3 * 0.13;
      const color = index % 2 ? "#b0d3e0" : "#8887b4";
      mesh.round(tx, 0.03, tz, 0.1, rose, color, 0.08, 5);
      mesh.round(tx, rose + 0.03, tz, 0.08, 0.12, color, 0, 5);
    } else if (kind === "flowerMeadow") {
      const flowers = ["#e59891", "#e6c675", "#a68ec3"];
      mesh.round(tx, 0.025, tz, 0.014, 0.20, "#538755", 0.012, 5);
      mesh.ball(tx, 0.24, tz, 0.071, flowers[index % 3]);
    } else if (kind === "desert") {
      mesh.round(tx, 0.02, tz, 0.27 + index % 3 * 0.06, 0.12, index % 2 ? "#e4c48e" : "#c99f65", 0.12, 7);
    } else if (kind === "lake") {
      const half = 0.19 + index % 3 * 0.10;
      mesh.face([[tx - half, .067, tz], [tx, .067, tz - 0.037], [tx + half, .067, tz], [tx, .067, tz + 0.026]], "#e0f5f1");
    }
  }
  return mesh.faces;
}

function buildWorld(data) {
  const island = [], ground = [], structures = [], labels = [], waterfalls = [], bounds = boardBounds(data.plots);
  islandGeometry(bounds, island, waterfalls);
  const terrainByPlot = new Map();
  for (const plot of data.plots) {
    if (!plot.terrain) continue;
    const [, kind, variant] = /^terrain-(.*)-(\d+)$/.exec(plot.terrain) || [];
    if (Object.hasOwn(terrainColors, kind)) terrainByPlot.set(plot.id, {kind, variant: Number(variant) - 1});
  }
  for (const plot of data.plots) {
    const [row, column] = splitID(plot.id);
    const x = column * 3, z = row * 3;
    const {kind, variant} = terrainByPlot.get(plot.id) || {};
    const variation = ((row * 7 + column * 3) % 5 + 5) % 5;
    const tint = plot.unlocked
      ? (kind ? finishColor(terrainColors[kind], variant) : shade("#599358", 0.96 + variation * 0.025))
      : "#527c68";
    ground.push(worldFace(coordinates(x, z, 3, 3, 0.001), tint, {texture: kind ? null : "grass"}));
    // Merged neighboring lakes share the water fill. Keep cell guides off the water.
    const edge = plot.unlocked ? (kind === "lake" ? null : "rgba(39,62,35,.47)") : "rgba(218,239,221,.37)";
    for (let subRow = 0; subRow < 3; subRow++) for (let subColumn = 0; subColumn < 3; subColumn++) {
      const cell = {plot, row: row * 3 + subRow, column: column * 3 + subColumn};
      const color = (subRow + subColumn) % 2 === 0 ? "rgba(247,255,225,.11)" : "rgba(30,56,29,.04)";
      ground.push(worldFace(coordinates(cell.column, cell.row, 1, 1, 0.014), kind === "lake" ? "transparent" : color, {
        edge: plot.unlocked && edge ? "rgba(60,85,46,.20)" : null, cell,
      }));
    }
    if (edge) ground.push(worldFace(coordinates(x, z, 3, 3, 0.024), null, {edge}));
    if (!plot.unlocked) labels.push({point: [x + 1.5, 0.23, z + 1.5], text: "100"});
    if (kind) {
      const strip = kind === "lake" ? "rgba(179,157,109,.72)" : "rgba(74,127,70,.28)";
      const boundaries = [
        [-1, 0, x + 0.09, z + 0.05, 2.82, 0.13], [1, 0, x + 0.09, z + 2.82, 2.82, 0.13],
        [0, -1, x + 0.05, z + 0.09, 0.13, 2.82], [0, 1, x + 2.82, z + 0.09, 0.13, 2.82],
      ];
      for (const [dr, dc, gx, gz, gw, gd] of boundaries) {
        if (terrainByPlot.get((row + dr) + ":" + (column + dc))?.kind !== kind) {
          ground.push(worldFace(coordinates(gx, gz, gw, gd, 0.032), strip));
        }
      }
      structures.push(...terrainMesh(kind, variant, row, column));
    }
  }
  for (const placement of data.placements) {
    if (!placement.asset) continue;
    addModel(structures, placement.asset, placement.anchorRow, placement.anchorColumn, placement.rotationQuarterTurns || 0, {placement});
  }
  return {island, ground, structures, labels, bounds, waterfalls};
}

function pointInPolygon(x, y, polygon) {
  let inside = false;
  for (let index = 0, previous = polygon.length - 1; index < polygon.length; previous = index++) {
    const [ax, ay] = polygon[index], [bx, by] = polygon[previous];
    if ((ay > y) !== (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax) inside = !inside;
  }
  return inside;
}

function project(camera, width, height, zoom) {
  const sine = Math.sin(camera.yaw * degrees), cosine = Math.cos(camera.yaw * degrees);
  const elevation = camera.elevation * degrees, above = Math.sin(elevation), horizon = Math.cos(elevation);
  return ([x, y, z]) => {
    const east = x - camera.x, north = z - camera.z;
    const sideways = east * cosine - north * sine, forward = east * sine + north * cosine;
    return [width / 2 + sideways * zoom, height * 0.42 + (forward * above - y * horizon) * zoom, forward * horizon + y * above];
  };
}

function projectedFaces(faces, projectPoint) {
  return faces.map((face) => {
    const polygon = face.points.map(projectPoint);
    const depth = polygon.reduce((sum, point) => sum + point[2], 0) / polygon.length;
    return {...face, polygon, depth};
  }).sort((first, second) => first.depth - second.depth);
}

function paintPolygon(ctx, face, patterns) {
  const {polygon} = face;
  ctx.beginPath();
  ctx.moveTo(polygon[0][0], polygon[0][1]);
  for (const [x, y] of polygon.slice(1)) ctx.lineTo(x, y);
  ctx.closePath();
  if (face.color && face.color !== "transparent") {
    ctx.fillStyle = face.color;
    ctx.fill();
  }
  if (patterns && face.texture && patterns[face.texture]) {
    ctx.fillStyle = patterns[face.texture];
    ctx.globalAlpha = face.texture === "grass" ? 0.20 : 0.29;
    ctx.fill();
    ctx.globalAlpha = 1;
  }
  if (face.edge) {
    ctx.lineWidth = 1;
    ctx.strokeStyle = face.edge;
    ctx.stroke();
  }
}

const textureImages = {
  grass: "/assets/grass-3d-texture.png",
  rock: "/assets/FloatingRockV354.png",
};

class RewardCityScene {
  constructor(canvas, camera, interaction) {
    this.canvas = canvas;
    this.ctx = canvas.getContext("2d");
    this.camera = camera;
    this.interaction = interaction;
    this.patterns = {};
    this.frame = 0;
    this.hover = null;
    this.hits = [];
    this.world = null;
    this.viewZoom = 1;
    if (!this.ctx) return;
    for (const [key, url] of Object.entries(textureImages)) {
      const image = new Image();
      image.onload = () => {
        const sample = document.createElement("canvas");
        sample.width = sample.height = key === "grass" ? 110 : 270;
        sample.getContext("2d").drawImage(image, 0, 0, sample.width, sample.height);
        this.patterns[key] = this.ctx.createPattern(sample, "repeat");
        this.draw();
      };
      image.src = url;
    }
    this.resize = new ResizeObserver(() => this.draw());
    this.resize.observe(canvas);
    canvas.addEventListener("pointerdown", (event) => this.begin(event));
    canvas.addEventListener("pointermove", (event) => this.move(event));
    canvas.addEventListener("pointerup", (event) => this.end(event));
    canvas.addEventListener("pointercancel", () => { this.drag = null; this.hover = null; this.draw(); });
    canvas.addEventListener("pointerleave", () => { this.hover = null; this.draw(); });
    canvas.addEventListener("wheel", (event) => {
      event.preventDefault();
      this.zoom(event.deltaY > 0 ? 0.88 : 1.12);
    }, {passive: false});
    canvas.addEventListener("contextmenu", (event) => event.preventDefault());
    canvas.addEventListener("keydown", (event) => {
      const keys = {
        "+": () => this.zoom(1.12), "=": () => this.zoom(1.12), "-": () => this.zoom(0.88),
        ArrowLeft: () => this.orbit(-15), ArrowRight: () => this.orbit(15),
        ArrowUp: () => this.orbit(0, 7), ArrowDown: () => this.orbit(0, -7), Home: () => this.center(),
      };
      if (keys[event.key]) { event.preventDefault(); keys[event.key](); }
    });
  }

  setData(data) {
    this.world = buildWorld(data);
    if (!this.camera.initialized) this.center();
    this.draw();
  }

  center() {
    const {x, z} = this.world.bounds;
    Object.assign(this.camera, {x, z, zoom: 1, initialized: true});
    this.draw();
  }

  orbit(angle, elevation = 0) {
    this.camera.yaw += angle;
    this.camera.elevation = Math.min(80, Math.max(16, this.camera.elevation + elevation));
    this.draw();
  }

  zoom(factor) {
    this.camera.zoom = Math.min(5, Math.max(0.35, this.camera.zoom * factor));
    this.draw();
  }

  draw() {
    if (!this.ctx || this.frame || !this.world) return;
    this.frame = requestAnimationFrame(() => {
      this.frame = 0;
      this.paint();
    });
  }

  paint() {
    if (!this.canvas.isConnected) { this.resize.disconnect(); return; }
    const width = this.canvas.clientWidth, height = this.canvas.clientHeight;
    if (!width || !height) return;
    const ratio = Math.min(2.5, window.devicePixelRatio || 1);
    const screenWidth = Math.round(width * ratio), screenHeight = Math.round(height * ratio);
    if (this.canvas.width !== screenWidth || this.canvas.height !== screenHeight) {
      this.canvas.width = screenWidth;
      this.canvas.height = screenHeight;
    }
    this.ctx.setTransform(ratio, 0, 0, ratio, 0, 0);
    this.ctx.clearRect(0, 0, width, height);
    const bounds = this.world.bounds;
    this.viewZoom = Math.min(width * 0.83 / Math.hypot(bounds.width, bounds.depth),
      height * 0.76 / (Math.hypot(bounds.width, bounds.depth) * 0.64 + bounds.drop * 0.78)) * this.camera.zoom;
    const projection = project(this.camera, width, height, this.viewZoom);
    this.hits = [];
    for (const layer of [this.world.island, this.world.ground, this.world.structures]) {
      const faces = layer === this.world.ground
        ? layer.map((face) => ({...face, polygon: face.points.map(projection)}))
        : projectedFaces(layer, projection);
      for (const face of faces) {
        if (face.placement || face.cell) this.hits.push(face);
        paintPolygon(this.ctx, face, this.patterns);
      }
    }
    const angle = this.camera.yaw * degrees;
    for (const {direction, strips} of this.world.waterfalls) {
      if (direction[0] * Math.sin(angle) + direction[1] * Math.cos(angle) > 0) {
        for (const face of strips) paintPolygon(this.ctx, {...face, polygon: face.points.map(projection)});
      }
    }
    for (const label of this.world.labels) this.paintLabel(label, projection);
    this.paintSelection(projection);
  }

  paintLabel({point, text}, projection) {
    const [x, y] = projection(point);
    const ctx = this.ctx;
    const badge = Math.min(38, Math.max(20, this.viewZoom * 2.0));
    const font = Math.min(11, Math.max(8, this.viewZoom * 0.64));
    ctx.font = "600 " + font + "px Segoe UI, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    ctx.beginPath();
    ctx.roundRect(x - badge / 2, y - 7, badge, 14, 5);
    ctx.fillStyle = "rgba(43,63,49,.89)";
    ctx.fill();
    ctx.fillStyle = "#f3f4dc";
    const left = x - badge / 2 + 4;
    ctx.fillText(text, left + 9, y + 0.4);
    ctx.fillRect(left, y - 1, 6, 4.6);
    ctx.lineWidth = 0.9;
    ctx.strokeStyle = "#f3f4dc";
    ctx.beginPath();
    ctx.arc(left + 3.5, y - 1.3, 2, Math.PI, Math.PI * 2);
    ctx.stroke();
  }

  paintSelection(projection) {
    const state = this.interaction.selection();
    const selected = state.placement;
    const hover = this.hover && this.hover.cell;
    const hoverPlacement = this.hover && this.hover.placement;
    const selection = this.drag?.placement || selected || hoverPlacement;
    if (selection?.asset && !state.asset) {
      const [w, d] = dimensions(selection.asset, selection.rotationQuarterTurns || 0);
      const points = coordinates(selection.anchorColumn, selection.anchorRow, w, d, 0.06);
      paintPolygon(this.ctx, worldFace(points, "rgba(247,239,156,.13)", {edge: "rgba(255,244,135,.95)", polygon: points.map(projection)}));
    }
    if (state.selectedTerrain) {
      const [row, col] = splitID(state.selectedTerrain);
      const points = coordinates(col * 3, row * 3, 3, 3, 0.07);
      paintPolygon(this.ctx, worldFace(points, "rgba(187,244,213,.14)", {edge: "#deffdf", polygon: points.map(projection)}));
    }
    if (!hover) return;
    const asset = this.drag?.placement?.asset || state.asset;
    const rotation = this.drag?.placement?.rotationQuarterTurns || state.rotation || 0;
    const terrain = this.drag?.terrain || state.terrain;
    if (asset && hover.plot.unlocked) {
      const [row, column] = nearestAnchor(asset, hover.row, hover.column, rotation);
      const [w, d] = dimensions(asset, rotation);
      const points = coordinates(column, row, w, d, 0.065);
      const possible = this.interaction.possible(asset, row, column, rotation, this.drag?.placement?.id);
      paintPolygon(this.ctx, worldFace(points, possible ? "rgba(193,237,163,.55)" : "rgba(238,118,98,.55)",
        {edge: possible ? "#f0ffe3" : "#ffc1a4", polygon: points.map(projection)}));
    } else if (terrain || hover.plot.frontier) {
      const [row, col] = splitID(hover.plot.id);
      const points = coordinates(col * 3, row * 3, 3, 3, 0.075);
      paintPolygon(this.ctx, worldFace(points, "rgba(247,239,156,.24)", {edge: "#fbecaf", polygon: points.map(projection)}));
    }
  }

  hit(event) {
    const rect = this.canvas.getBoundingClientRect();
    const x = event.clientX - rect.left, y = event.clientY - rect.top;
    let placement = null, cell = null;
    for (let index = this.hits.length - 1; index >= 0 && !(placement && cell); index--) {
      const candidate = this.hits[index];
      if (!pointInPolygon(x, y, candidate.polygon)) continue;
      placement ||= candidate.placement || null;
      cell ||= candidate.cell || null;
    }
    return {cell, placement};
  }

  begin(event) {
    if (event.button > 2) return;
    this.canvas.focus({preventScroll: true});
    const hit = this.hit(event);
    const placing = this.interaction.selection().asset || this.interaction.selection().terrain;
    const allowDrag = event.button === 0 && !event.altKey && !event.shiftKey && !placing;
    this.drag = {
      startX: event.clientX, startY: event.clientY, x: event.clientX, y: event.clientY,
      active: false, orbit: event.button === 2 || event.altKey,
      placement: allowDrag ? hit.placement : null,
      terrain: allowDrag && !hit.placement ? hit.cell?.plot.terrain && hit.cell.plot.id : null,
    };
    this.canvas.setPointerCapture(event.pointerId);
  }

  move(event) {
    const drag = this.drag;
    this.hover = this.hit(event);
    if (drag) {
      if (Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) > 5) drag.active = true;
      if (drag.active && !drag.placement && !drag.terrain) {
        const dx = event.clientX - drag.x, dy = event.clientY - drag.y;
        if (drag.orbit) this.orbit(dx * 0.36, dy * 0.22);
        else {
          const along = -dx / this.viewZoom, forward = -dy / this.viewZoom / Math.sin(this.camera.elevation * degrees);
          const sine = Math.sin(this.camera.yaw * degrees), cosine = Math.cos(this.camera.yaw * degrees);
          this.camera.x += along * cosine + forward * sine;
          this.camera.z += -along * sine + forward * cosine;
        }
      }
      drag.x = event.clientX;
      drag.y = event.clientY;
    }
    this.draw();
  }

  end(event) {
    const drag = this.drag, hit = this.hit(event);
    this.drag = null;
    if (!drag) return;
    if (drag.active) {
      if (hit.cell?.plot.unlocked && drag.placement) this.interaction.move(drag.placement, hit.cell);
      else if (hit.cell?.plot.unlocked && drag.terrain) this.interaction.moveTerrain(drag.terrain, hit.cell.plot.id);
    } else if (event.button === 0) this.interaction.activate(hit);
    else if (event.button === 2) this.interaction.context(hit, event.clientX, event.clientY);
    this.draw();
  }

  dispose() {
    this.resize?.disconnect();
    if (this.frame) cancelAnimationFrame(this.frame);
  }
}

function previewAsset(canvas, asset) {
  if (!asset || !canvas.getContext("2d")) return;
  const ctx = canvas.getContext("2d"), faces = [];
  const ratio = Math.min(2, window.devicePixelRatio || 1);
  const width = Number(canvas.getAttribute("width")), height = Number(canvas.getAttribute("height"));
  canvas.width = width * ratio;
  canvas.height = height * ratio;
  ctx.scale(ratio, ratio);
  addModel(faces, asset, 0, 0, 0);
  const camera = {x: asset.width / 2, z: asset.depth / 2, yaw: 35, elevation: 32};
  const projector = project(camera, width, height * 1.55, Math.min(width, height) * 0.74 / Math.max(asset.width, asset.depth));
  for (const face of projectedFaces(faces, projector)) paintPolygon(ctx, face);
}

function previewTerrain(canvas, kind, variant) {
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const width = canvas.width, height = canvas.height;
  const faces = terrainMesh(kind, variant, 0, 0);
  const base = new Mesh();
  base.box(1.5, -0.22, 1.5, 3, 0.24, 3, terrainColors[kind]);
  const projection = project({x: 1.5, z: 1.5, yaw: 43, elevation: 39}, width, height * 1.17, Math.min(width, height) * 0.25);
  for (const face of projectedFaces([...base.faces, ...faces], projection)) paintPolygon(ctx, face);
}

window.RewardCityScene = RewardCityScene;
window.rewardCityPreview = {asset: previewAsset, terrain: previewTerrain, plotForCell, dimensions};
}());

