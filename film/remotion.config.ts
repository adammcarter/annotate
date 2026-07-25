import { Config } from "@remotion/cli/config";

Config.setVideoImageFormat("png");
Config.setOverwriteOutput(true);
// The film is mostly flat colour and type over dark. PNG stills + a low CRF
// keeps the ink's soft edges from banding, which h264 does aggressively on
// large near-black areas.
// CRF is passed per-render instead of set here: the GIF codec rejects the
// option outright, and a config-level default made `--codec=gif` fail with an
// error that pointed at the CLI rather than at this file.
