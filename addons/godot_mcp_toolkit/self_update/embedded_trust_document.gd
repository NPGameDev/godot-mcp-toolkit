@tool
extends RefCounted
## The trust document this release starts its chain from: the text of the highest file
## under the repository's [code]trust/[/code] folder.
##
## It is read without checking its signatures, since the release's own signature carries
## it. While it is empty there is no chain and no trusted key, so the toolkit offers updates
## as links only.

const DOCUMENT := ""
