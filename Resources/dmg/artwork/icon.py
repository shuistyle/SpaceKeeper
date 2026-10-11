# Draws SpaceKeeper.icns and icon_1024.png (needs Python + Pillow).
from PIL import Image, ImageDraw, ImageFilter
S=4; N=1024*S
img=Image.new("RGBA",(N,N),(0,0,0,0))
def rr(d,box,r,fill): d.rounded_rectangle([int(v*S) for v in box],radius=int(r*S),fill=fill)
# shadow
sh=Image.new("RGBA",(N,N),(0,0,0,0)); d=ImageDraw.Draw(sh); rr(d,(100,112,924,936),185,(0,0,0,110))
sh=sh.filter(ImageFilter.GaussianBlur(14*S)); img.alpha_composite(sh)
# body gradient (navy -> slate)
body=Image.new("RGBA",(N,N)); bd=ImageDraw.Draw(body)
for y in range(N):
    t=y/N; c=tuple(int(a+(b-a)*t) for a,b in zip((28,44,72),(14,22,38))); bd.line([(0,y),(N,y)],fill=c+(255,))
mask=Image.new("L",(N,N),0); rr(ImageDraw.Draw(mask),(100,100,924,924),185,255)
img.paste(body,(0,0),mask)
d=ImageDraw.Draw(img)
cols=[(0xF0,0xE4,0x42),(0x56,0xB4,0xE9),(0xE6,0x9F,0x00),(0x4C,0xC9,0xA0),(0xE0,0x8F,0xBE),(0xFF,0xFF,0xFF)]
x0,y0,w,h,g=210,300,180,128,32
i=0
for r in range(2):
    for c in range(3):
        x=x0+c*(w+g); y=y0+r*(h+g)
        col=cols[i]
        if i==5: d.rounded_rectangle([int(v*S) for v in (x+5,y+5,x+w-5,y+h-5)],radius=22*S,outline=(255,255,255,200),width=8*S)
        else: rr(d,(x,y,x+w,y+h),26,col+(255,))
        i+=1
# pin on first tile (simple map-pin shape)
px,py=x0+w-38,y0-6
d.ellipse([int(v*S) for v in (px-34,py-34,px+34,py+34)],fill=(214,40,40,255))
d.polygon([(int((px-26)*S),int((py+18)*S)),(int((px+26)*S),int((py+18)*S)),(int(px*S),int((py+70)*S))],fill=(214,40,40,255))
d.ellipse([int(v*S) for v in (px-12,py-12,px+12,py+12)],fill=(255,255,255,255))
# label bar
rr(d,(210,672,814,732),30,(255,255,255,230))
rr(d,(240,691,520,713),11,(28,44,72,255))
out=img.resize((1024,1024),Image.LANCZOS); out.save("icon_1024.png")
out.save("SpaceKeeper.icns",sizes=[(16,16),(32,32),(64,64),(128,128),(256,256),(512,512),(1024,1024)])
