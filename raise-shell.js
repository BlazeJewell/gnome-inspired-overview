// KWin script, run each time the overview opens. Raises the shell's own
// full-screen window (bar popouts, launcher, dashboard) above the overview,
// which shares its layer and would otherwise cover them. That window only
// takes clicks over the bar and open panels, so the overview keeps the rest.
for (const w of workspace.stackingOrder) {
    const out = w.output ? w.output.geometry : null;
    const g = w.frameGeometry;
    if (w.resourceClass === "quickshell" && out && g.width === out.width && g.height === out.height && !w.normalWindow && w.layer >= 3)
        workspace.raiseWindow(w);
}
