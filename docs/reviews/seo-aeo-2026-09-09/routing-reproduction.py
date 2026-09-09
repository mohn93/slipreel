import subprocess,urllib.request,urllib.error,time,json
proc=subprocess.Popen(['caddy','run','--config','/tmp/slipreel-seo-test.Caddyfile','--adapter','caddyfile'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
class NoRedirect(urllib.request.HTTPRedirectHandler):
 def redirect_request(self,*args):return None
client=urllib.request.build_opener(NoRedirect)
def fetch(path):
 try:r=client.open('http://127.0.0.1:18765'+path,timeout=3)
 except urllib.error.HTTPError as e:r=e
 return r.code,r.headers.get('Location')
try:
 for i in range(20):
  try:fetch('/');break
  except OSError:time.sleep(.1)
 checks=[]
 for name in ['guide','downloads','changelog','privacy','screen-studio-alternative','loom-alternative','screenflow-alternative','quicktime-alternative']:
  checks.append(('/'+name,(200,None)))
  for alias in ['/'+name+'.html','/'+name+'/']:
   checks.extend([(alias,(308,'/'+name)),(alias+'?utm_source=seo&x=a%2Bb',(308,'/'+name+'?utm_source=seo&x=a%2Bb'))])
 checks.extend([('/index.html',(308,'/')),('/index.html?utm_source=seo',(308,'/?utm_source=seo')),('/index',(308,'/')),('/',(200,None)),('/not-a-real-page',(404,None))])
 for name in ['login','account','pricing','success','cancel']:
  checks.extend([('/'+name+'.html?token=synthetic-test',(200,None)),('/'+name,(200,None))])
 for p,expected in checks:
  actual=fetch(p);assert actual==expected,(p,expected,actual)
 print(json.dumps({'checks':len(checks),'result':'passed','query_preserved':True,'auth_paths_unchanged':True}))
finally:proc.terminate();proc.wait(timeout=5)
