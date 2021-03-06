#!/usr/bin/env julia

using DocOpt

import Celeste.ParallelRun: BoundingBox, get_overlapping_fields
import Celeste.SDSSIO: RunCamcolField


const DOC =
"""List all Run-Camcol-Field triplets that overlap with a specified
bounding box. Output is in a format that can be piped to make, with the
makefile in this directory, e.g.

    ./list_rcfs.jl -999 999 -999 999 | sort -R | xargs -P 32 -n 1 make

Usage:
  list_rcfs.jl <ramin> <ramax> <decmin> <decmax>
  list_rcfs.jl -h | --help
"""

function main()
    args = docopt(DOC, version=v"0.1.0", options_first=true)

    box = BoundingBox(args["<ramin>"], args["<ramax>"],
                      args["<decmin>"], args["<decmax>"])
    rcfs = get_overlapping_fields(box, dirname(ENV["FIELD_EXTENTS"]))

    for rcf in rcfs
        println("RUN=$(rcf.run) CAMCOL=$(rcf.camcol) FIELD=$(rcf.field)")
    end
end


main()
