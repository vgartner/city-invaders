import bpy,math,json,argparse,sys
from pathlib import Path
from mathutils import Vector
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description="Render the retained and finished URB-07 under matching studio lighting")
parser.add_argument('--output',type=Path,required=True)
args=parser.parse_args(sys.argv[sys.argv.index('--')+1:])
out=args.output.resolve();out.mkdir(parents=True,exist_ok=True)
for label,source in [('before',root/'tools/blender/src/urb07_finish/robot_palette_source.glb'),('after',root/'godot/assets/common/enemies/robot/robot.glb')]:
 bpy.ops.wm.read_factory_settings(use_empty=True);bpy.ops.import_scene.gltf(filepath=str(source));s=bpy.context.scene
 for o in s.objects:
  if o.animation_data:
   o.animation_data.action=None
   for tr in o.animation_data.nla_tracks:tr.mute=tr.name!='idle'
 s.frame_set(1)
 if label=='after':
  for i in bpy.data.images:
   if i.source=='FILE':i.pack()
  bpy.ops.wm.save_as_mainfile(filepath=str(out/'urb07_finish.blend'))
 s.render.engine='CYCLES';s.cycles.samples=24;s.cycles.use_denoising=True
 s.render.resolution_x=1000;s.render.resolution_y=1000;s.render.resolution_percentage=100
 s.world=bpy.data.worlds.new('Neutral studio');s.world.use_nodes=True;s.world.node_tree.nodes['Background'].inputs[0].default_value=(.32,.38,.45,1);s.world.node_tree.nodes['Background'].inputs[1].default_value=.7
 bpy.ops.object.light_add(type='AREA',location=(-3,-4,5));bpy.context.object.data.energy=600;bpy.context.object.data.shape='DISK';bpy.context.object.data.size=4;bpy.context.object.rotation_euler=(Vector((0,0,1))-bpy.context.object.location).to_track_quat('-Z','Y').to_euler()
 bpy.ops.object.light_add(type='AREA',location=(3,2,3));bpy.context.object.data.energy=450;bpy.context.object.data.size=3;bpy.context.object.rotation_euler=(Vector((0,0,1))-bpy.context.object.location).to_track_quat('-Z','Y').to_euler()
 bpy.ops.object.camera_add();cam=bpy.context.object;s.camera=cam;cam.data.type='ORTHO';s.view_settings.view_transform='AgX'
 for suffix,loc,target,scale in [('front',(0,5,1.1),(0,0,1),2.55),('threequarter',(3,5,2.5),(0,0,1),2.55),('back',(-2,-5,2.5),(0,0,1),2.55),('detail',(1.3,3,2),(0,0,1.52),1.05)]:
  cam.location=loc;cam.rotation_euler=(Vector(target)-cam.location).to_track_quat('-Z','Y').to_euler();cam.data.ortho_scale=scale;s.render.filepath=str(out/(label+'_'+suffix+'.png'));bpy.ops.render.render(write_still=True)
 print('DONE',label,flush=True)
