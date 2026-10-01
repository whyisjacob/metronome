import puppeteer from 'puppeteer';
import fs from 'node:fs';
import path from 'node:path';
const [rawDir,outDir,W='1320',H='2868']=process.argv.slice(2);
if(!rawDir||!outDir)throw Error('rawDir outDir width height required');
fs.mkdirSync(outDir,{recursive:true});
const walk=d=>fs.readdirSync(d,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(d,e.name)):[path.join(d,e.name)]);
const files=walk(rawDir);
const font=n=>fs.readFileSync(new URL('./fonts/'+n,import.meta.url)).toString('base64');
const panels=[
 ['01','Find your<br>pocket.','Your beat. Your pace. Your metronome.','#ffca38','#181525','PRACTICE STARTS HERE','01'],
 ['03','Count it.<br>Play it.','Spoken counts that make rhythm click.','#bdb0ff','#211341','COUNT ALONG. PLAY STRONG.','02'],
 ['04','One song.<br>Every change.','Map the tempo. Shape each section.','#8aead1','#062d2c','BUILD YOUR TEMPO MAP','03'],
 ['02','Odd time?<br>Good time.','Explore meters, accents & subdivisions.','#ff967d','#341619','MAKE THE TRICKY PART CLICK','04'],
 ['07','Trust your<br>inner clock.','Drop the beat. Keep your groove.','#a9d7ff','#0e2544','MEET YOUR GAP TRAINER','05'],
 ['01','Buy once.<br>Play for keeps.','No subscriptions. No in-app purchases. Ever.','#ffe493','#241d15','EVERY FEATURE INCLUDED','06']
];
const browser=await puppeteer.launch({headless:true});
const page=await browser.newPage();
await page.setViewport({width:+W,height:+H,deviceScaleFactor:1});
for(const [prefix,title,sub,bg,ink,label,num]of panels){
 const raw=files.find(f=>path.basename(f).startsWith(prefix+'-')&&f.endsWith('.png'));
 if(!raw){console.log('SKIP '+prefix);continue;}
 const img=fs.readFileSync(raw).toString('base64');
 const html=`<!doctype html><style>
 @font-face{font-family:Display;src:url(data:font/woff2;base64,${font('montserrat-800.woff2')});font-weight:800}
 @font-face{font-family:Body;src:url(data:font/woff2;base64,${font('space-grotesk-500.woff2')})}
 *{box-sizing:border-box}body{margin:0;background:${bg};color:${ink};font-family:Body;overflow:hidden}
 .canvas{width:1320px;height:${+H*1320/+W}px;transform:scale(${+W/1320});transform-origin:top left;position:relative;overflow:hidden}
 .brand{position:absolute;top:76px;left:84px;font-size:35px;letter-spacing:7px;font-family:Display}.index{position:absolute;right:84px;top:77px;font-size:32px;opacity:.6}
 h1{position:absolute;top:179px;left:78px;margin:0;font:800 148px/.98 Display;letter-spacing:-8px;z-index:2}
 .sub{position:absolute;left:84px;top:516px;right:80px;font-size:40px;line-height:1.3;z-index:2}
 .ring{position:absolute;width:1700px;height:1700px;border:70px solid ${ink};opacity:.075;border-radius:50%;top:970px;left:-220px}.ring:after{content:'';position:absolute;inset:100px;border:50px solid ${ink};border-radius:50%}
 .beats{position:absolute;top:644px;left:84px;display:flex;gap:14px}.beats i{width:22px;height:22px;border-radius:50%;background:${ink};opacity:.25}.beats i:first-child{opacity:1;width:58px;border-radius:20px}
 .phone{position:absolute;top:757px;left:221px;width:878px;padding:13px;background:#11131b;border:4px solid #43444d;border-radius:87px;box-shadow:0 45px 75px ${ink}40;transform:rotate(${num==='01'?-3:num==='03'?2:0}deg);z-index:1}
 .phone img{display:block;width:100%;height:auto;border-radius:70px}
 footer{position:absolute;bottom:0;height:147px;width:100%;background:${bg};display:flex;align-items:center;justify-content:space-between;padding:0 84px;font-size:25px;letter-spacing:3px;z-index:3;border-top:2px solid ${ink}20}
 .star{position:absolute;right:80px;top:620px;font-size:148px;line-height:1;transform:rotate(12deg)}
 </style><div class=canvas><div class=brand>MAELZEL</div><div class=index>${num} / 06</div><h1>${title}</h1><div class=sub>${sub}</div><div class=beats><i></i><i></i><i></i><i></i></div><div class=star>✳</div><div class=ring></div><div class=phone><img src="data:image/png;base64,${img}"></div><footer><span>${label}</span><span>MAKE TIME FOR MUSIC ↗</span></footer></div>`;
 await page.setContent(html);await page.evaluate(()=>document.fonts.ready);await page.screenshot({path:path.join(outDir,num+'-Maelzel.png')});console.log(num+' rendered from '+raw);
}
const finished=fs.readdirSync(outDir).filter(f=>/^\d\d-Maelzel\.png$/.test(f)).sort();
await page.setViewport({width:1320,height:Math.ceil(finished.length/3)*956,deviceScaleFactor:1});
await page.setContent('<style>body{margin:0;display:grid;grid-template-columns:repeat(3,440px);background:#fff}img{width:440px;height:956px;object-fit:contain}</style>'+finished.map(f=>'<img src="data:image/png;base64,'+fs.readFileSync(path.join(outDir,f)).toString('base64')+'">').join(''));
await page.screenshot({path:path.join(outDir,'contact-sheet.jpg'),type:'jpeg',quality:92});
await browser.close();


