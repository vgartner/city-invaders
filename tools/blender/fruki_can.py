"""Build the Fruki can; metres, Z-up source / Y-up glTF, front -Z.

Blender -b --python fruki_can.py -- OUTPUT_DIR TEXTURE_DIR [--previews]
All branding and microfinish are packed into one atlas material.
"""
import bpy
import math
import json
import sys
from pathlib import Path
from mathutils import Vector


def build(out, textures, previews=False):
    out, textures = Path(out), Path(textures)
    out.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    material = bpy.data.materials.new('fruki_pbr_atlas')
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    bsdf = nodes.get('Principled BSDF')
    for kind, color_space in [('basecolor','sRGB'),('normal','Non-Color'),('metallic_roughness','Non-Color')]:
        image = bpy.data.images.load(str(textures / f'fruki_{kind}.png'))
        image.colorspace_settings.name = color_space
        image.pack()
        tex = nodes.new('ShaderNodeTexImage'); tex.image = image
        tex.interpolation = 'Linear'; tex.extension = 'REPEAT'
        if kind == 'basecolor':
            links.new(tex.outputs['Color'],bsdf.inputs['Base Color'])
        elif kind == 'normal':
            normal = nodes.new('ShaderNodeNormalMap')
            normal.inputs['Strength'].default_value = 0.28
            links.new(tex.outputs['Color'],normal.inputs['Color'])
            links.new(normal.outputs['Normal'],bsdf.inputs['Normal'])
        else:
            separate = nodes.new('ShaderNodeSeparateColor')
            links.new(tex.outputs['Color'],separate.inputs['Color'])
            links.new(separate.outputs['Green'],bsdf.inputs['Roughness'])
            links.new(separate.outputs['Blue'],bsdf.inputs['Metallic'])
    vertices, faces, uvfaces = [], [], []

    def face(indices, coords):
        faces.append(indices); uvfaces.append(coords)

    def metal_uv(co, dark=False):
        if dark: return (0.93 + co[0]*3,0.065 + co[1]*3 + (co[2]-.117)*2)
        return (0.35 + co[0]*6 + co[2]*.8, 0.21 + co[1]*2.0 + co[2]*.7)

    def lathe(profile, segments=48, painted=False):
        start=len(vertices)
        for radius,z in profile:
            for j in range(segments):
                theta=2*math.pi*j/segments-math.pi/2
                vertices.append((radius*math.sin(theta),-radius*math.cos(theta),z))
        for k in range(len(profile)-1):
            # The printed coat follows the outer shoulder but never the seam/lid.
            ink=painted and k>=4 and k<=13
            for j in range(segments):
                nj=(j+1)%segments
                ids=(start+k*segments+j,start+k*segments+nj,start+(k+1)*segments+nj,start+(k+1)*segments+j)
                if ink:
                    lo=.5+.5*(profile[k][1]-.0058)/(.1155-.0058)
                    hi=.5+.5*(profile[k+1][1]-.0058)/(.1155-.0058)
                    uv=((j/segments,lo),((j+1)/segments,lo),((j+1)/segments,hi),(j/segments,hi))
                else: uv=[metal_uv(vertices[i]) for i in ids]
                face(ids,uv)
        return start

    profile=[(.0275,0),(.0285,.0006),(.0293,.0016),(.0295,.0030),
             (.0301,.0058),(.0318,.0072),(.0328,.0090),(.033,.011),
             (.033,.1035),(.0327,.106),(.0319,.1082),(.0304,.1106),
             (.0288,.1130),(.0281,.1142),(.0280,.1155),
             (.0286,.1164),(.0296,.1171),(.0301,.1182),(.0300,.1197),
             (.0292,.1211),(.0283,.1220),(.0275,.1213),(.0272,.1200),
             (.0276,.1188),(.0273,.1180),(.0256,.1175),(.0236,.1171)]
    lathe(profile, painted=True)

    def disc(radius,z,segments=48,up=True):
        c=len(vertices); vertices.append((0,0,z))
        for i in range(segments):
            t=2*math.pi*i/segments
            vertices.append((radius*math.cos(t),radius*math.sin(t),z))
        for i in range(segments):
            ids=(c,c+1+i,c+1+(i+1)%segments)
            if not up:ids=ids[::-1]
            face(ids,[metal_uv(vertices[j]) for j in ids])
    disc(.0236,.1171)
    # Closed, domed underside, safely above the contact ring at z=0.
    base=[(.0275,0),(.0265,.0015),(.0245,.0033),(.017,.0044)]
    offset=lathe(base)
    for i in range(len(faces)-(len(base)-1)*48,len(faces)):
        faces[i]=faces[i][::-1];uvfaces[i]=uvfaces[i][::-1]
    disc(.017,.0044,up=False)

    # Thin stamped pull-tab, real offset hole, top and bottom skin + side walls.
    count=28; start=len(vertices)
    for z in [.1178,.1187]:
        for inner in [False,True]:
            for i in range(count):
                t=2*math.pi*i/count
                x=(.0037 if inner else .0056)*math.cos(t)
                y=(.0048 if inner else .0097)*math.sin(t)+(.0052 if inner else .0017)
                vertices.append((x,y,z))
    for i in range(count):
        n=(i+1)%count
        for ids in [(start+2*count+i,start+2*count+n,start+3*count+n,start+3*count+i),
                    (start+i,start+count+i,start+count+n,start+n),
                    (start+i,start+n,start+2*count+n,start+2*count+i),
                    (start+count+i,start+3*count+i,start+3*count+n,start+count+n)]:
            face(ids,[metal_uv(vertices[j]) for j in ids])

    # Rivet and narrow scored opening; no transparent fake hole in a sealed can.
    lathe([(.0017,.1172),(.0019,.1182),(.0015,.1192)],segments=16)
    disc(.0015,.1192,segments=16)
    # Elliptical score on the cap, in front of the pull-tab.
    start=len(vertices); count=36
    for inner in [False,True]:
        for i in range(count):
            t=2*math.pi*i/count
            f=.965 if inner else 1.0
            vertices.append((.0082*math.cos(t)*f,-.010+.0095*math.sin(t)*f,.11717))
    for i in range(count):
        n=(i+1)%count
        ids=(start+i,start+n,start+count+n,start+count+i)
        face(ids,[metal_uv(vertices[j],True) for j in ids])

    mesh=bpy.data.meshes.new('fruki_can_geometry')
    mesh.from_pydata(vertices,[],faces);mesh.update()
    uv=mesh.uv_layers.new(name='UVMap')
    for poly,coords in zip(mesh.polygons,uvfaces):
        for loop,coord in zip(poly.loop_indices,coords): uv.data[loop].uv=coord
        poly.use_smooth=True
    # Keep lid/tab planes planar; rounded walls retain radial shading.
    for poly in mesh.polygons:
        if abs(poly.normal.z)>.999:poly.use_smooth=False
    obj=bpy.data.objects.new('fruki_can',mesh)
    bpy.context.collection.objects.link(obj);obj.data.materials.append(material)
    bpy.context.view_layer.objects.active=obj;obj.select_set(True)
    # Bake triangulation to keep Blender/Godot normals and triangle budgets aligned.
    modifier=obj.modifiers.new('GameTriangles','TRIANGULATE')
    bpy.ops.object.modifier_apply(modifier=modifier.name)
    for image in bpy.data.images:
        if image.source=='FILE':image.pack()
    bpy.ops.wm.save_as_mainfile(filepath=str(out/'fruki.blend'))
    bpy.ops.export_scene.gltf(filepath=str(out/'fruki.glb'),export_format='GLB',
        use_selection=True,export_apply=True,export_yup=True,export_cameras=False,
        export_lights=False,export_animations=False,export_tangents=True)
    report={'triangles':len(obj.data.polygons),'vertices':len(obj.data.vertices),
        'dimensions_m':list(obj.dimensions),'materials':1,'meshes':1,
        'logo_centres_u':[.25,.75],'logo_angles_degrees':[0,180],
        'origin':'ground centre','texture_dimensions':[2048,2048],
        'atlas_wrap_v':[.5,1.0]}
    (out/'model_report.json').write_text(json.dumps(report,indent=2))
    if previews: render_previews(obj,out)
    return obj


def render_previews(obj,out):
    scene=bpy.context.scene
    scene.render.engine='CYCLES';scene.cycles.samples=40
    scene.render.resolution_x=1100;scene.render.resolution_y=850
    scene.render.resolution_percentage=100
    scene.world=bpy.data.worlds.new('preview_world')
    scene.world.use_nodes=True
    scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.25,.28,.32,1)
    scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.35
    scene.view_settings.view_transform='AgX'
    scene.view_settings.look='AgX - Medium High Contrast'
    scene.view_settings.exposure=0
    bpy.ops.mesh.primitive_plane_add(size=200,location=(0,0,-.0002))
    floor=bpy.context.object
    mat=bpy.data.materials.new('preview_ground');mat.use_nodes=True
    mat.node_tree.nodes['Principled BSDF'].inputs['Base Color'].default_value=(.12,.14,.16,1)
    mat.node_tree.nodes['Principled BSDF'].inputs['Roughness'].default_value=.7
    floor.data.materials.append(mat)
    def aim(node,at):node.rotation_euler=(Vector(at)-node.location).to_track_quat('-Z','Y').to_euler()
    for name,at,energy,size in [('key',(-.15,-.22,.32),3.4,.21),('fill',(.18,-.08,.18),1.0,.20),('edge',(.07,.2,.28),4.0,.18)]:
        data=bpy.data.lights.new(name,'AREA');data.energy=energy;data.shape='DISK';data.size=size
        node=bpy.data.objects.new(name,data);scene.collection.objects.link(node);node.location=at;aim(node,(0,0,.06))
    data=bpy.data.cameras.new('preview_camera');camera=bpy.data.objects.new('preview_camera',data)
    scene.collection.objects.link(camera);scene.camera=camera
    camera.location=(0,-.33,.16);aim(camera,(0,0,.061))
    data.type='ORTHO';data.ortho_scale=.19;data.clip_start=.001
    (out/'previews').mkdir(exist_ok=True)
    for name,angle in [('front',0),('back',math.pi),('three_quarter',math.pi/5)]:
        obj.rotation_euler.z=angle
        scene.render.filepath=str(out/'previews'/f'{name}.png')
        bpy.ops.render.render(write_still=True)
    obj.rotation_euler.z=0
    camera.location=(.08,-.10,.205);aim(camera,(0,0,.111));data.ortho_scale=.085
    scene.render.filepath=str(out/'previews'/'lid.png');bpy.ops.render.render(write_still=True)


if __name__=='__main__':
    args=sys.argv[sys.argv.index('--')+1:]
    build(args[0],args[1], '--previews' in args)
