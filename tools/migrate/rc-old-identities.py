# Extract one old user's Roundcube identities from the old roundcubedb dump as JSON (for tools/rc-apply-identities.php).
# Usage: python3 -I tools/rc-old-identities.py old-roundcubedb.sql.gz alice "old@example.org,shared@example.org" > ids.json
#   (the optional third argument: identities to leave out, e.g. addresses that no longer exist)
import gzip, re, collections
def rows(sql, table):
    out=[]
    for m in re.finditer(r"INSERT INTO `%s` VALUES (.*?);\n" % table, sql, re.S):
        s=m.group(1); i=0; n=len(s)
        while i<n:
            if s[i]!='(': i+=1; continue
            i+=1; row=[]; 
            while True:
                if s[i]=="'":
                    i+=1; buf=[]
                    while s[i]!="'":
                        if s[i]=='\\': buf.append({'n':'\n','r':'\r','t':'\t','0':'\0'}.get(s[i+1],s[i+1])); i+=2
                        else: buf.append(s[i]); i+=1
                    i+=1; row.append(''.join(buf))
                else:
                    j=i
                    while s[i] not in ',)': i+=1
                    v=s[j:i]; row.append(None if v=='NULL' else v)
                if s[i]==',': i+=1; continue
                if s[i]==')': i+=1; break
            out.append(row)
    return out
def unser(s, i=0):
    t=s[i]
    if t=='N': return None, i+2
    if t in 'bid':
        j=s.index(';',i); v=s[i+2:j]; return (v=='1' if t=='b' else float(v) if t=='d' else int(v)), j+1
    if t=='s':
        j=s.index(':',i+2); L=int(s[i+2:j]); b=s.encode('utf-8'); 
        # byte-length strings: work in bytes
        pre=len(s[:j+2].encode()); v=b[pre:pre+L].decode('utf-8','replace'); 
        return v, len(b[:pre+L+2].decode('utf-8','replace'))
    if t=='a':
        j=s.index(':',i+2); n=int(s[i+2:j]); i=j+2; d={}
        for _ in range(n):
            k,i=unser(s,i); v,i=unser(s,i); d[k]=v
        return d, i+1
    raise ValueError(t)
import sys, json
sql=gzip.open(sys.argv[1],'rt',encoding='utf-8',errors='replace').read()
users=rows(sql,'users'); ids=rows(sql,'identities')
u=sorted([u for u in users if u[1]==sys.argv[2]], key=lambda u: u[4] or '')[-1]   # most recent login
drop=set(filter(None,(sys.argv[3] if len(sys.argv)>3 else '').split(',')))
json.dump([{"standard":int(r[4]),"name":r[5],"organization":r[6] or "","email":r[7],"replyto":r[8] or "","signature":r[10] or "","html_signature":int(r[11])}
           for r in ids if r[1]==u[0] and r[3]=='0' and r[7] not in drop], sys.stdout)
