# API and safety changes in 2.6.36

## Native tables

CleanZip uses public AppKit table APIs, not a reimplementation of Finder's private internals:

- `NSTableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle` resizes the name column with the viewport. Other columns retain their user-selected widths. Native horizontal scrolling remains available when the columns cannot fit.
- `NSTableColumn.resizingMask` separates user resizing from automatic resizing. Columns retain minimum widths but no longer have the small, application-defined maximum widths that stopped divider dragging.
- All columns and constraints are created before `autosaveTableColumns` is enabled. AppKit restores widths and order at that point. A legacy layout that displaced the name column is repaired without resetting the other columns.
- `tableView(_:shouldReorderColumn:toColumn:)` accepts AppKit's `-1` drag-start query for non-name columns and rejects moves into the name slot or outside the valid column range. Column selection remains disabled.

References: [column autoresizing styles](https://developer.apple.com/documentation/appkit/nstableview/columnautoresizingstyle-swift.enum), [column width constraints](https://developer.apple.com/documentation/appkit/nstablecolumn/width), [autosave and restoration](https://developer.apple.com/documentation/appkit/nstableview/autosavetablecolumns), [column reordering delegate](https://developer.apple.com/documentation/appkit/nstableviewdelegate/tableview(_:shouldreordercolumn:tocolumn:)).

Regression tests instantiate the production table factories, exercise extreme widths, resize narrow/wide viewports repeatedly, reorder columns, and reconstruct saved layouts. These tests verify AppKit configuration and layout behavior; they do not establish pixel-for-pixel or gesture-for-gesture equivalence to Finder.

## File APIs and archive safety

- Open panels use completion-based `beginSheetModal(for:completionHandler:)` or `begin(completionHandler:)`, avoiding a nested application-modal event loop. The panel is ordered out before processing selected URLs.
- Services declare `NSSendFileTypes` and read file URLs using `NSPasteboard.readObjects(forClasses:options:)`. The pre-10.6 filename pasteboard declarations and the incorrectly typed `.fileURL` property-list fallback are removed.
- Extraction propagates download quarantine with `URLResourceValues.quarantineProperties`, including hidden files and application bundles. Symbolic links are not followed when applying attributes. Failure to preserve quarantine prevents publication.
- Compression and extraction write inside a private, same-volume workspace. Publication uses exclusive rename, so existing output is not overwritten. Cancellation removes only task-owned output, not similarly named archives or volumes.
- 7-Zip receives literal selected paths and explicit metadata exclusions. Split compression returns the first volume that actually exists. Known compressed TAR formats are decoded through both layers.

References: [open panels](https://developer.apple.com/documentation/appkit/nssavepanel/beginsheetmodal(for:completionhandler:)), [Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html), [quarantine properties](https://developer.apple.com/documentation/foundation/urlresourcevalues/quarantineproperties).

## Build and compatibility

Release builds select the newest installed stable Xcode 26 on the GitHub Actions runner, compile in Swift 6 strict-concurrency mode, and verify `arm64` and `x86_64` slices. The minimum deployment target remains macOS 14. SDK 27 is not required for this release.

Local tests can select an available SDK explicitly:

```sh
CLEANZIP_SDK=/path/to/MacOSX.sdk work/CleanZipBuild/tests/run.sh
```

The same safety tests run against both the app engine and Finder service engine. The main suite additionally covers UI state replacement, table behavior, encrypted archives, and ZIP/7Z split output. Native runtime checks on one OS or architecture do not replace testing on every supported macOS release and CPU.
