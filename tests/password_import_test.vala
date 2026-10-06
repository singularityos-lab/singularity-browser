using Singularity.Apps.Browser;

void test_chrome () {
    int skipped;
    var list = PasswordImport.parse ("name,url,username,password,note\r\nexample.com,https://example.com/login?x=1,ann,\"s3cr\"\"et\",\r\nbad,ftp://x.org,bob,pw,\r\n,https://Example.com:443/other,ann,dup,\r\nempty,https://e.org,eve,,\r\n", "default", out skipped);
    assert (list.length == 1);
    assert (list[0].origin == "https://example.com");
    assert (list[0].username == "ann");
    assert (list[0].password == "s3cr\"et");
    assert (skipped == 3);
}

void test_quoted_google () {
    int skipped;
    var list = PasswordImport.parse ("\xef\xbb\xbfname,url,username,password,note\n\"a, b\",\"https://site.test:8443/p\",\"me@x\",\"p,w\nline\",\"n\"\n", "work", out skipped);
    assert (list.length == 1);
    assert (list[0].origin == "https://site.test:8443");
    assert (list[0].password == "p,w\nline");
    assert (list[0].profile == "work");
}

void test_firefox_and_bitwarden () {
    int skipped;
    var ff = PasswordImport.parse ("\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://a.org\",\"u\",\"p\",\"\"\n", "default", out skipped);
    assert (ff.length == 1 && ff[0].origin == "https://a.org");
    var bw = PasswordImport.parse ("folder,favorite,type,name,notes,fields,reprompt,login_uri,login_username,login_password,login_totp\n,,login,A,,,0,https://b.org/x,v,q,\n", "default", out skipped);
    assert (bw.length == 1 && bw[0].origin == "https://b.org" && bw[0].username == "v");
}

void test_not_an_export () {
    int skipped;
    try {
        PasswordImport.parse ("a,b\n1,2\n", "default", out skipped);
        assert_not_reached ();
    } catch (Error e) {
    }
}

int main (string[] args) {
    Test.init (ref args);
    Test.add_func ("/password-import/chrome", test_chrome);
    Test.add_func ("/password-import/quoted", test_quoted_google);
    Test.add_func ("/password-import/other-formats", test_firefox_and_bitwarden);
    Test.add_func ("/password-import/rejects", test_not_an_export);
    return Test.run ();
}
