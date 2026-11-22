# PCXT ZXTres documentation

This folder is the documentation site of PCXT for the ZXTRES, ZXTRES+ and
ZXTRES++, ready to be served by GitHub Pages from the `main` branch, folder
`/docs` (published at <https://aitorgomez-net.github.io/PCXT_ZXTres/>). The
pages link to each other with relative links, and `.nojekyll` turns Jekyll off
so the files are served as they are.

## Pages

* [`index.html`](index.html) — home page and navigation.
* [`guide.html`](guide.html) — getting started: which file for each board, the microSD card, loading the core, first boot, video, keys, joysticks, mouse, disks, audio and troubleshooting.
* [`builds.html`](builds.html) — the boards and builds: feature matrix of the full core and the four ZXTRES (A35T) builds, differences from MiSTer, FPGA resources and timing, the optimisations that make the A35T builds fit, building and verification.
* [`osd.html`](osd.html) — OSD reference: every page and option, when it is shown, and the menu of each ZXTRES build.
* [`report/CORE_REPORT.html`](report/CORE_REPORT.html) — technical report of the whole core: the machines, architecture, CGA/Tandy/PCjr, HGC/MDA and EGA video, the ZXTres video path, memory map, OSD and startup.
* [`assets/`](assets) — the shared stylesheet and the ZXTres boot splash.

## Notes

* [`8086-adaptation.md`](8086-adaptation.md) — source-of-truth notes for the selectable 8088/8086 implementation (shared with the MiSTer core).
* [`../zxtres/README.md`](../zxtres/README.md) and [`../zxtres/SPEC.md`](../zxtres/SPEC.md) — the port: what it does, its state, decisions and remaining work.
* [`../vendor/pc_common/README.md`](../vendor/pc_common/README.md) — the EGA card: origin, SDRAM retiming and benches.
* [`../rtl/common/jtframe_credits.md`](../rtl/common/jtframe_credits.md) — credits asset format.
* [`../SW/XTCTL/README.txt`](../SW/XTCTL/README.txt) — legacy XTCTL utility and its runtime overrides.

The root [`README.md`](../README.md) is the entry point of the repository.

## Editing

Links between pages are relative (`guide.html`, `report/CORE_REPORT.html`);
links to files elsewhere in the repository use their full github.com URL,
because only `docs/` is served by Pages. `scripts/check_doc_links.py` checks
both rules and that every local link resolves.
