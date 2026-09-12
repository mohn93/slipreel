#!/usr/bin/env python3
"""Create a reviewable preview from the website's original, local product clips."""
import pathlib, subprocess, json, hashlib
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'dist/app-store';out.mkdir(parents=True,exist_ok=True)
clips=[('hero.mp4',9),('beat-zoom.mp4',9),('beat-frames.mp4',9)]
args=['ffmpeg','-y','-v','error']
for filename,_ in clips: args+=['-i',str(root/'site/assets/video'/filename)]
args+=['-f','lavfi','-i','anullsrc=r=48000:cl=stereo']
filters=[]
for i,(_,duration) in enumerate(clips):
    filters.append(f'[{i}:v]trim=duration={duration},setpts=PTS-STARTPTS,fps=30,scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1[v{i}]')
filters.append('[v0][v1][v2]concat=n=3:v=1:a=0[v]')
target=out/'slipreel-app-preview-draft.mp4'
args+=['-filter_complex',';'.join(filters),'-map','[v]','-map','3:a','-t','27','-c:v','libx264','-preset','medium','-crf','18','-profile:v','high','-level','4.0','-pix_fmt','yuv420p','-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-c:a','aac','-b:a','192k','-movflags','+faststart',str(target)]
subprocess.run(args,check=True)
info=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_format','-show_streams','-of','json',str(target)]))
video=next(s for s in info['streams'] if s['codec_type']=='video')
assert (video['width'],video['height'],video['r_frame_rate'])==(1920,1080,'30/1')
assert 15<=float(info['format']['duration'])<=30
(out/'preview-manifest.json').write_text(json.dumps({'status':'draft; verify store-edition feature parity and add native app workflow footage before submission','source':'local website originals; 720p sources upscaled to 1080p','clips':clips,'sha256':hashlib.sha256(target.read_bytes()).hexdigest(),'probe':info},indent=2))
subprocess.run(['ffmpeg','-y','-v','error','-ss','1','-i',str(target),'-frames:v','1',str(out/'preview-poster.png')],check=True)
print(target)
