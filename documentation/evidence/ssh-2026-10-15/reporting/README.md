# V13 report provenance and reproduction

`report-artifact.json` records the unchanged v12 input and delivered v13 DOCX/PDF hashes. The 179-page PDF and DOCX are delivered alongside the original report in the workspace documentation directory. They are not stored as large binaries in this infrastructure repository.

The scripts perform narrowly scoped edits against the exact v12 input hash, retain its existing artwork and structure, add two evidence charts, refresh 164 static contents entries, and qualify older release results. They are version-specific, not generic document editors.

Tooling used: Python 3.12.14, python-docx 1.2.0, pypdf 6.10.0, matplotlib 3.10.7; the packaged documents renderer uses LibreOffice and page PNG rendering. `analyze.py` derives the tables and charts offline. Re-running it in a fresh copy reproduces the retained results (excluding generation timestamp) and both chart PNGs byte for byte.

Reproduction sequence, with paths supplied as quoted arguments:

1. Run `build_v13.py V12.docx V13.docx EVIDENCE_DIRECTORY` against the input identified by `report-artifact.json`.
2. Render V13 to a fresh directory and retain the PDF and every page PNG.
3. Run `update_toc.py V13.docx RENDERED_V13.pdf contents-audit.json`.
4. Run `finalize_v13.py V13.docx` for the contents label, historical release qualification and narrow table-label font adjustment.
5. Render again, validate contents page numbers, inspect every changed page, and establish byte identity for unchanged pages already inspected.

`visual-qa.json` records complete visual coverage. `contents-audit.json` validates every contents title against its final rendered page. All 119 original media files remain byte-identical; two chart images were added. Seven compact historical API summaries/manifests were also verified byte-identical to the 7 October originals. Reproduction can vary in binary ZIP metadata and renderer output across tool/platform versions; the submitted hashes identify the actual reviewed outputs.
