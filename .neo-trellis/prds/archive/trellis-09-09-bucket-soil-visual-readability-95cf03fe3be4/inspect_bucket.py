"""Offline GLB section evidence; does not mutate product assets."""
import json
import struct
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw

OUT = Path(__file__).parent / 'research'
OUT.mkdir(exist_ok=True)

def bucket(model):
    raw = Path(f'godot/client/assets/visual/{model.upper()}_excavator_godot.glb').read_bytes()
    size = struct.unpack_from('<I', raw, 12)[0]
    doc = json.loads(raw[20:20+size])
    binary = raw[28+size:]
    def accessor(i):
        a=doc['accessors'][i]; v=doc['bufferViews'][a['bufferView']]
        dtype={5126:'<f4',5125:'<u4',5123:'<u2'}[a['componentType']]
        count={'VEC3':3,'VEC2':2,'SCALAR':1}[a['type']]
        return np.ndarray((a['count'],count),dtype=dtype,buffer=binary,
            offset=v.get('byteOffset',0)+a.get('byteOffset',0),
            strides=(v.get('byteStride',np.dtype(dtype).itemsize*count),np.dtype(dtype).itemsize)).copy()
    node=next(n for n in doc['nodes'] if n.get('name')=='bucket')
    # Mesh node is the pivot's direct child in both validated manifests.
    if 'matrix' in node:
        transform=np.array(node['matrix']).reshape(4,4).T
    else:
        x,y,z,w=node.get('rotation',[0,0,0,1])
        rotation=np.array([[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
            [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
            [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]])
        transform=np.eye(4); transform[:3,:3]=rotation@np.diag(node.get('scale',[1,1,1]))
        transform[:3,3]=node.get('translation',[0,0,0])
    prim=doc['meshes'][node['mesh']]['primitives'][0]
    vertices=accessor(prim['attributes']['POSITION'])
    p=vertices@transform[:3,:3].T+transform[:3,3]
    ids=accessor(prim['indices']).reshape(-1,3)
    contract=json.loads(Path(f'godot/client/resources/models/{model}_soil_contract.json').read_text())
    cavity=contract['proxies']['cavity']
    up=np.array(cavity['up_godot']); up/=np.linalg.norm(up)
    basis=np.column_stack(([1,0,0],up,np.cross([1,0,0],up)))
    q=(p-cavity['center_godot'])@basis
    return q,ids,basis,cavity

def section(q,ids,x):
    result=[]
    for index,tri in enumerate(q[ids]):
        hits=[]
        for a,b in zip(tri,np.roll(tri,-1,axis=0)):
            if (a[0]<=x<b[0]) or (b[0]<=x<a[0]):
                hits.append(a+(b-a)*(x-a[0])/(b[0]-a[0]))
        if len(hits)==2:
            result.append((index,hits))
    return result

if __name__=='__main__':
    for model in ['sy135','sy205']:
        q,ids,basis,cavity=bucket(model)
        im=Image.new('RGB',(1250,850),'white'); d=ImageDraw.Draw(im)
        def xy(p): return (int(660+p[2]*550),int(430-p[1]*550))
        for i in range(-10,11):
            d.line([xy([0,-1,i*.1]),xy([0,1,i*.1])],fill='#eeeeee')
            d.line([xy([0,i*.1,-1.2]),xy([0,i*.1,1])],fill='#eeeeee')
            d.text(xy([0,0,i*.1]),str(round(i*.1,1)),fill='gray')
            d.text(xy([0,i*.1,0]),str(round(i*.1,1)),fill='gray')
        d.text((20,15),model+' cavity local section: horizontal Z, vertical Y. Black x=0; blue x=.4; red proxy',fill='black')
        for x,color in [(0.4,'#94b7d6'),(0,'black')]:
            for index,hits in section(q,ids,x):
                d.line([xy(p) for p in hits], fill=color,width=2)
                if x==0:
                    middle=np.mean(hits,axis=0)
                    d.text(xy(middle),str(index),fill='#9a3939')
        sy,sz=np.array(cavity['size_m'])[1:]*.5
        d.rectangle([xy([0,sy,-sz]),xy([0,-sy,sz])],outline='red',width=2)
        im.save(OUT/f'{model}-section.png')
        (OUT/f'{model}-mesh.json').write_text(json.dumps({'vertices':q.tolist(),'triangles':ids.tolist()}))
        print(model,'mesh bounds',q.min(axis=0).round(3),q.max(axis=0).round(3))
