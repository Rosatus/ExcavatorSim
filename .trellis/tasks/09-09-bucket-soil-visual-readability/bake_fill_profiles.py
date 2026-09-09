"""Bake a presentation-only upper envelope of the unchanged bucket triangles.

Run with the project's numpy-enabled Python. The vertical axis is model-specific:
SY135 grows toward -cavity.Y; SY205 grows toward +cavity.Y. This is measured visual
geometry, not a change to the semantic cavity or the material ledger.
"""
import hashlib
import json
from pathlib import Path
import numpy as np
from inspect_bucket import bucket

SETTINGS = {
    'sy135': (-1.0, [-0.507, 0.507], [-0.415, 0.572], -0.08),
    'sy205': (1.0, [-0.62, 0.62], [-0.88, 0.54], -0.10),
}

def height_at(q, ids, x, z, direction):
    tri=q[ids]
    a,b,c=tri[:,0],tri[:,1],tri[:,2]
    denominator=(b[:,2]-c[:,2])*(a[:,0]-c[:,0])+(c[:,0]-b[:,0])*(a[:,2]-c[:,2])
    valid=np.abs(denominator)>1e-9
    denominator=np.where(valid,denominator,1)
    u=((b[:,2]-c[:,2])*(x-c[:,0])+(c[:,0]-b[:,0])*(z-c[:,2]))/denominator
    v=((c[:,2]-a[:,2])*(x-c[:,0])+(a[:,0]-c[:,0])*(z-c[:,2]))/denominator
    valid &= (u>=-1e-6)&(v>=-1e-6)&(u+v<=1+1e-6)
    heights=(u*a[:,1]+v*b[:,1]+(1-u-v)*c[:,1])*direction
    return float(np.max(heights[valid])) if np.any(valid) else None

if __name__=='__main__':
    for model,(direction,x_bounds,z_bounds,rim) in SETTINGS.items():
        q,ids,_,cavity=bucket(model)
        columns,rows=25,33
        floors=[]
        for row,z in enumerate(np.linspace(*z_bounds,rows)):
            for column,x in enumerate(np.linspace(*x_bounds,columns)):
                height=height_at(q,ids,x,z,direction)
                # Dry perimeter and missing rays terminate the clipped solid;
                # there is no artificial suspended rectangle at its base.
                if height is None or row in (0,rows-1) or column in (0,columns-1):
                    height=rim+0.04
                floors.append(round(height,6))
        asset=Path(f'godot/client/assets/visual/{model.upper()}_excavator_godot.glb')
        data={
            'schema_version':'bucket-fill-profile-v1','model_id':model,
            'source_sha256':hashlib.sha256(asset.read_bytes()).hexdigest(),
            'coordinate_space':'cavity_local','growth_direction_y':direction,
            'cavity_center_godot':cavity['center_godot'],'cavity_up_godot':cavity['up_godot'],
            'columns':columns,'rows':rows,'x_bounds':x_bounds,'z_bounds':z_bounds,
            'rim_height':rim,'floor_heights':floors,
        }
        path=Path(f'godot/client/resources/visual/{model}_bucket_fill_profile.json')
        path.write_text(json.dumps(data,indent=2)+'\n')
        print(model, 'samples',len(floors),'floor_min',min(floors),'rim',rim)
