# Native speech acknowledgements

VoiceRelay embeds the shared native Swift MLX helper. Its pinned upstream license
and notice files are bundled in `Contents/Resources/ThirdPartyNotices`, sourced
from the independent swift-packages repository. Python interpreter, package and
FFmpeg implementations are not bundled or used.

Model/voice and pronunciation data are explicitly prepared external assets,
verified against the common native catalogs. See the shared dependency provenance
and model repositories for those datasets' licensing; the app bundle does not
redistribute the model weights.
