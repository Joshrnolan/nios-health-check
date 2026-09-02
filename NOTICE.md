# Third-Party Notices

This project (`nios-health-check`) is licensed under the MIT License (see
`LICENSE`). The script ships as a single file, `nios_health_check.py`.
Two clearly-marked, optional sections inside that file (Section 2 and
Section 3 — search for the `SECTION 2` / `SECTION 3` banner comments)
adapt logic from other MIT-licensed projects. Per the MIT license terms,
their original copyright and permission notices are reproduced below and
must stay intact if this code is redistributed.

---

## 1. Grid Member Capacity Report (Section 2 of `nios_health_check.py`)

Adapted from `**nios_grid_capacity.py**` by Pat Vogelsang
([https://github.com/pvogelsang67/nios_grid_capacity](https://github.com/pvogelsang67/nios_grid_capacity)).

```
MIT License

Copyright (c) 2026 Pat Vogelsang

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

What was reused: the `capacityreport` WAPI query shape, the per-object-type
flattening approach, and the DDI/Active-IP object estimation heuristic
(`estimate_uddi_objects`). Re-implemented as `generate_capacity_report()`
inside `nios_health_check.py`, running on the health check script's
existing authenticated WAPI session instead of as a standalone CLI tool.

---

## 2. DNS Topology Visualizer (Section 3 of `nios_health_check.py`)

Adapted from `**ddi_collect.py**` / `**ddi_dashboard.html**`, part of the NIOS
DDI Dashboard tool, written by Bobby Cooper
([https://github.com/robdcooper/NIOS-DDI-Dashboard](https://github.com/robdcooper/NIOS-DDI-Dashboard)).


```
MIT License

Copyright (c) 2026 Bobby Cooper.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

What was reused: the `build_topology()` zone-relationship graph builder
(hierarchy / primary / secondary / forwards / delegated / stub edges) and the
ECharts-based relationship-graph and zone-hierarchy-tree rendering from the
dashboard's "DNS Topology" tab. The Overview and IPAM tabs, the live
`ddi_serve.py` companion server, and the browser "Collect" workflow were
intentionally dropped — `generate_topology_viz()` inside
`nios_health_check.py` collects once (reusing the health check
script's existing WAPI session) and embeds the result into a single
self-contained static HTML file, with the dashboard's HTML/CSS/JS kept as
the `TOPOLOGY_HTML_TEMPLATE` string constant in that same section.