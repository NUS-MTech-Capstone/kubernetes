from pathlib import Path
import argparse,re,json
from docx import Document
from pypdf import PdfReader
p=argparse.ArgumentParser();p.add_argument('document',type=Path);p.add_argument('pdf',type=Path);p.add_argument('audit',type=Path);a=p.parse_args()
d=Document(a.document);normal=lambda s:re.sub(r'[^a-z0-9]','',s.lower());pages=[normal(p.extract_text()) for p in PdfReader(a.pdf).pages];changes=[]
for p in d.paragraphs[7:180]:
 if '\t' not in p.text:continue
 title,num=p.text.rsplit('\t',1)
 if not num.isdigit():continue
 newtitle='22.1 Lessons' if title=='22.1 Lessons from implementation' else title
 matches=[i+1 for i,s in enumerate(pages) if i>=5 and normal(newtitle) in s]
 if not matches:raise ValueError(title)
 new=min(matches)
 if newtitle!=title:
  for run in p.runs:run.text=run.text.replace('Lessons from implementation','Lessons')
 # Static contents entries retain their original tabs and formatting.
 for run in reversed(p.runs):
  if run.text.endswith(num):run.text=run.text[:-len(num)]+str(new);break
 else:raise ValueError('No terminal page run: '+title)
 changes.append({'heading':newtitle,'oldPage':int(num),'page':new})
d.save(a.document);a.audit.write_text(json.dumps({'pageCount':len(pages),'entries':changes},indent=2)+'\n');print('Updated',len(changes),'contents references')
