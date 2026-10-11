# Draws the DMG window background at 1x and 2x (needs Python + Pillow and the Inter font).
from PIL import Image, ImageDraw, ImageFont
W,H=680,480
APP=(180,190); APPS=(500,190); GUIDE=(340,385)
def font(w,s): return ImageFont.truetype(f"/usr/share/fonts/opentype/inter/Inter-{w}.otf",s)
for k in (1,2):
    im=Image.new("RGB",(W*k,H*k),(245,247,250)); d=ImageDraw.Draw(im)
    ink=(27,36,51); blue=(0,90,140)
    def ct(y,t,f,fill=ink): 
        w=d.textlength(t,font=f); d.text(((W*k-w)/2,y*k),t,font=f,fill=fill)
    ct(26,"Install SpaceKeeper",font("Bold",30*k))
    ct(70,"Drag the SpaceKeeper icon onto the Applications folder.",font("Medium",17*k))
    # arrow
    y=APP[1]*k; x1=(APP[0]+78)*k; x2=(APPS[0]-78)*k
    d.line([(x1,y),(x2-22*k,y)],fill=blue,width=10*k)
    d.polygon([(x2,y),(x2-30*k,y-20*k),(x2-30*k,y+20*k)],fill=blue)
    d.line([(60*k,290*k),(620*k,290*k)],fill=(200,206,214),width=2*k)
    ct(304,"Opening it for the first time?",font("Bold",17*k))
    ct(328,"Double-click this guide. It takes about a minute.",font("Medium",15*k))
    im.save("background.png" if k==1 else "background@2x.png", dpi=(72*k,72*k))
