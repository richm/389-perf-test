import sys
import time
import ldap

url, binddn, bindpw, basedn, nconns, niters = sys.argv[1:]

conns = []
for ii in xrange(0, int(nconns)):
    conn = ldap.initialize(url)
    conns.append(conn)

for conn in conns:
    conn.simple_bind(binddn, bindpw)

for ii in xrange(0, int(niters)):
    for conn in conns:
        ents = conn.search_s(basedn, ldap.SCOPE_SUBTREE, "uid=scarter")
        assert(len(ents) == 1)
        assert(ents[0][1]['uid'][0] == 'scarter')

for conn in conns:
    conn.unbind_s()
