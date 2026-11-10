"""Pure port adaptation, physical layout and filesystem helpers for the runner."""
from __future__ import annotations

from collections import Counter
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import tempfile


class FlowError(RuntimeError):
    def __init__(self, message, category="validation", **details):
        super().__init__(message)
        self.category = category
        self.details = details


def require(value, message, **details):
    if not value:
        raise FlowError(message, **details)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def file_digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        while block := source.read(1024 * 1024):
            result.update(block)
    return result.hexdigest()


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def atomic_write(path, text):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and path.read_text() == text:
        return
    fd, temporary = tempfile.mkstemp(prefix=".write-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as target:
            target.write(text)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def atomic_json(path, value):
    atomic_write(path, json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")


def tcl_word(value):
    value = str(value)
    require(not any(c in value for c in "{}\n\r"), f"Unsupported Tcl value: {value!r}")
    return "{" + value + "}"


def index_range(bounds):
    left, right = bounds
    return range(left, right + (1 if right >= left else -1), 1 if right >= left else -1)


def port_shape(port):
    typ, dimensions = port["type"], []
    while typ["kind"] == "unpackarraydtype":
        dimensions.append(typ["range"])
        typ = typ["element"]
    require(typ["kind"] == "basicdtype" and typ["name"] in ("logic", "bit", "int", "integer"),
            f"Unsupported hard-macro port: {port['name']} ({typ})")
    packed = typ.get("range")
    width = abs(packed[0] - packed[1]) + 1 if packed else 1
    indices = list(itertools.product(*(index_range(d) for d in dimensions))) if dimensions else [()]
    return typ, dimensions, width, indices


def declarations(ports, flat):
    result = []
    for port in ports:
        typ, dims, width, indices = port_shape(port)
        signed = " signed" if typ.get("signed") else ""
        if flat:
            count = width * len(indices)
            packed = f" [{count - 1}:0]" if count > 1 else ""
            suffix = ""
        else:
            packed = f" [{typ['range'][0]}:{typ['range'][1]}]" if "range" in typ else ""
            suffix = "".join(f" [{a}:{b}]" for a, b in dims)
        result.append(f"    {port['direction']} logic{signed}{packed} {port['name']}{suffix}")
    return ",\n".join(result)


def macro_name(name):
    return name + "__hard"


def wrappers(record):
    """Return packed physical wrapper, original-interface adapter, stub and map."""
    name, ports = record["name"], record["ports"]
    flat_ports = declarations(ports, True)
    head = "// Generated fixed-width wiring adapter.\n`default_nettype none\n"
    wrapper = [head, f"module {macro_name(name)} (\n{flat_ports}\n);\n"]
    adapter = [head, f"module {name} (\n{declarations(ports, False)}\n);\n"]
    wrapper_links, adapter_links, mapping = [], [], {}
    for port in ports:
        p = port["name"]
        typ, dims, width, indices = port_shape(port)
        count = width * len(indices)
        signed = " signed" if typ.get("signed") else ""
        packed = f" [{typ['range'][0]}:{typ['range'][1]}]" if "range" in typ else ""
        suffix = "".join(f" [{a}:{b}]" for a, b in dims)
        wrapper.append(f"logic{signed}{packed} rtl_{p}{suffix};\n")
        adapter.append(f"logic{signed}" + (f" [{count - 1}:0]" if count > 1 else "") + f" flat_{p};\n")
        bits = []
        for index, subscripts in enumerate(indices):
            actual = p + "".join(f"[{i}]" for i in subscripts)
            flat = p if count == 1 else f"{p}[{index * width} +: {width}]"
            if port["direction"] == "input":
                wrapper.append(f"assign rtl_{actual} = {flat};\n")
                adapter.append(f"assign flat_{flat} = {actual};\n")
            else:
                require(port["direction"] == "output", f"Inout ports are not supported: {p}")
                wrapper.append(f"assign {flat} = rtl_{actual};\n")
                adapter.append(f"assign {actual} = flat_{flat};\n")
            # Packed low-order bits map to the right bound, preserving direction.
            packed_bits = list(index_range([typ["range"][1], typ["range"][0]])) if "range" in typ else [None]
            for bit, original_bit in enumerate(packed_bits):
                bits.append({"flat_bit": index * width + bit,
                             "rtl": actual + (f"[{original_bit}]" if original_bit is not None else "")})
        mapping[p] = {"direction": port["direction"], "width": count, "bits": bits}
        wrapper_links.append(f".{p}(rtl_{p})")
        adapter_links.append(f".{p}(flat_{p})")
    wrapper.append(f"{name} u_rtl (" + ",".join(wrapper_links) + ");\nendmodule\n`default_nettype wire\n")
    adapter.append(f"{macro_name(name)} u_macro (" + ",".join(adapter_links) + ");\nendmodule\n`default_nettype wire\n")
    stub = head + f"(* blackbox *) module {macro_name(name)} (\n{flat_ports}\n);\nendmodule\n`default_nettype wire\n"
    return "".join(wrapper), "".join(adapter), stub, mapping


def expected_pins(record):
    result = set()
    for port in record["ports"]:
        _, _, width, indices = port_shape(port)
        count = width * len(indices)
        result.update([port["name"]] if count == 1 else [f"{port['name']}[{i}]" for i in range(count)])
    return result


def validate_views(record, lef, lib):
    lef_text, lib_text = Path(lef).read_text(), Path(lib).read_text()
    name = macro_name(record["name"])
    require(re.search(r"\bMACRO\s+" + re.escape(name) + r"\s", lef_text), f"Wrong LEF macro name: {name}")
    require(re.search(r'\bcell\s*\(\s*"?' + re.escape(name) + r'"?\s*\)', lib_text), f"Wrong Liberty cell name: {name}")
    size = re.search(r"\bSIZE\s+([\d.eE+-]+)\s+BY\s+([\d.eE+-]+)\s*;", lef_text)
    require(size and all(float(x) > 0 for x in size.groups()), f"Missing LEF dimensions: {name}")
    lef_pins = set(re.findall(r"\bPIN\s+(\S+)", lef_text))
    lib_pins = set(re.findall(r'\bpin\s*\(\s*"?([^"\s)]+)"?\s*\)', lib_text))
    expected = expected_pins(record)
    require(lef_pins - {"VDD", "VSS"} == expected, f"LEF signal pins mismatch: {name}")
    require(lib_pins - {"VDD", "VSS"} == expected, f"Liberty signal pins mismatch: {name}")
    require({"VDD", "VSS"} <= lef_pins, f"Missing LEF power pins: {name}")
    require(re.search(r"\bclock\s*:\s*true", lib_text), f"Missing clock attribute: {name}")
    return {"width_um": float(size[1]), "height_um": float(size[2])}


def ceil_grid(value, grid):
    return math.ceil((value - 1e-9) / grid) * grid


def layout_plan(request):
    """Deterministic placements from actual OpenDB geometry, never guessed LEFs."""
    kind, macros = request["kind"], request["macros"]
    cfg = request["config"]
    qx, qy = request["site_width_um"], request["site_height_um"]
    require(qx > 0 and qy > 0, "Invalid site grid")
    gap = max(cfg["macro_channel_um"], 2 * cfg["macro_halo_um"])
    margin = cfg["core_margin_um"]
    util = cfg["standard_cell_utilization"]
    require(0 < util <= 1 and gap >= 0 and margin > 0, "Invalid physical configuration")
    for macro in macros:
        require(macro["width_um"] > 0 and macro["height_um"] > 0, "Invalid macro dimensions")
    area = sum(m["width_um"] * m["height_um"] for m in macros) + request["standard_cell_area_um2"] / util
    planned = []
    def add(m, x, y):
        planned.append({**m, "x": x, "y": y, "orientation": "R0"})
    if not macros:
        width = height = max(math.sqrt(area), qy * 4)
    elif kind == "pe":
        require(len(macros) == 1, "PE requires exactly one SRAM macro")
        m = macros[0]
        width = max(math.sqrt(area), m["width_um"] + 2 * gap)
        height = max(area / width, m["height_um"] + 2 * gap)
        add(m, (width - m["width_um"]) / 2, (height - m["height_um"]) / 2)
    elif kind == "sa":
        rows, cols = request["rows"], request["cols"]
        require(len(macros) == rows * cols, "Wrong PE macro count")
        m = macros[0]
        require(all((x["width_um"], x["height_um"]) == (m["width_um"], m["height_um"]) for x in macros), "Mixed PE geometry")
        width = cols * m["width_um"] + max(0, cols - 1) * (gap + qx)
        height = rows * m["height_um"] + max(0, rows - 1) * (gap + qy)
        scale = max(1, math.sqrt(area / (width * height)))
        width, height = width * scale, height * scale
        dx = (width - m["width_um"]) / (cols - 1) if cols > 1 else 0
        dy = (height - m["height_um"]) / (rows - 1) if rows > 1 else 0
        seen = set()
        for inst in macros:
            row = re.search(r"gen_pe_row\[(\d+)\]", inst["name"])
            col = re.search(r"gen_pe_col\[(\d+)\]", inst["name"])
            require(row and col, f"Cannot locate PE array indices: {inst['name']}")
            r, c = int(row[1]), int(col[1])
            require(0 <= r < rows and 0 <= c < cols and (r, c) not in seen, "Invalid/duplicate PE indices")
            seen.add((r, c))
            add(inst, c * dx, (rows - 1 - r) * dy)
    else:
        sa = [m for m in macros if m["master"].startswith("sa__")]
        require(kind == "top" and len(sa) == 1, "Top requires exactly one SA macro")
        groups = {}
        for m in macros:
            if m in sa:
                continue
            match = re.fullmatch(r"(.*)gen_bank\[(\d+)\](.*)", m["name"])
            require(match, f"Unrecognized operand bank: {m['name']}")
            groups.setdefault(match[1], []).append((int(match[2]), m))
        require(len(groups) == 2, "Top requires two operand SRAM bank groups")
        a, b = [sorted(v) for _, v in sorted(groups.items())]
        require(len(a) == request["rows"] and len(b) == request["cols"], "Wrong operand bank count")
        aw = max(m["width_um"] for _, m in a)
        bh = max(m["height_um"] for _, m in b)
        ah = sum(m["height_um"] + gap + qy for _, m in a)
        bw = sum(m["width_um"] + gap + qx for _, m in b)
        sw, sh = max(sa[0]["width_um"], bw), max(sa[0]["height_um"], ah)
        width, height = aw + gap + sw, sh + gap + bh
        scale = max(1, math.sqrt(area / (width * height)))
        extra_x, extra_y = width * (scale - 1) / 2, height * (scale - 1) / 2
        width, height = width * scale, height * scale
        add(sa[0], extra_x + aw + gap + (sw - sa[0]["width_um"]) / 2,
            extra_y + (sh - sa[0]["height_um"]) / 2)
        for i, (_, m) in enumerate(a):
            add(m, extra_x, extra_y + sh - (i + 1) * (m["height_um"] + gap + qy))
        for i, (_, m) in enumerate(b):
            add(m, extra_x + aw + gap + i * (m["width_um"] + gap + qx), extra_y + sh + gap)
    # Reserve snapping slack at every edge; native place_macro snaps to tracks.
    width, height = ceil_grid(width + 2 * qx, qx), ceil_grid(height + 2 * qy, qy)
    ox, oy = ceil_grid(margin, qx), ceil_grid(margin, qy)
    for p in planned:
        p["x"], p["y"] = ceil_grid(p["x"] + ox, qx), ceil_grid(p["y"] + oy, qy)
    core = [ox, oy, ox + width, oy + height]
    check_placements(planned, core)
    return {"core": core, "die": [0, 0, ceil_grid(core[2] + margin, qx), ceil_grid(core[3] + margin, qy)],
            "placements": planned, "standard_cell_area_um2": request["standard_cell_area_um2"]}


def check_placements(placements, core):
    boxes = []
    for p in placements:
        box = (p["x"], p["y"], p["x"] + p["width_um"], p["y"] + p["height_um"])
        require(core[0] - 1e-6 <= box[0] and core[1] - 1e-6 <= box[1]
                and box[2] <= core[2] + 1e-6 and box[3] <= core[3] + 1e-6, f"Macro outside core: {p['name']}")
        boxes.append((box, p["name"]))
    # Sweep X to keep 4096-PE checks small; adjacent/touching rectangles are legal.
    active = []
    for box, name in sorted(boxes):
        active = [(b, n) for b, n in active if b[2] > box[0] + 1e-6]
        for other, other_name in active:
            require(not (box[1] < other[3] - 1e-6 and other[1] < box[3] - 1e-6),
                    f"Overlapping macros: {name}, {other_name}")
        active.append((box, name))


def emit_layout(request_path, output_path):
    result = layout_plan(json.loads(Path(request_path).read_text()))
    atomic_json(Path(output_path).with_suffix(".json"), result)
    text = "set hr_core " + tcl_word(" ".join(map(str, result["core"]))) + "\n"
    text += "set hr_die " + tcl_word(" ".join(map(str, result["die"]))) + "\nset hr_placements [list\n"
    for p in result["placements"]:
        text += f"  [list {tcl_word(p['name'])} {p['x']} {p['y']}]\n"
    atomic_write(output_path, text + "]\n")
