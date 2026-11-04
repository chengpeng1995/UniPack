// UniPack file-only signing entry point. Never imports Security.framework or opens a keychain.
#include "bundle.h"
#include "common.h"
#include "json.h"
#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/evp.h>
#include <openssl/x509.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <fstream>
#include <iostream>
#include <memory>
#include <algorithm>

static string readFile(const string &path, bool secret=false) {
    int fd=open(path.c_str(),O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0) throw string("无法打开指定文件");
    struct stat st{};
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_size>4*1024*1024 || (secret && (st.st_uid!=getuid() || (st.st_mode&077)!=0))) {close(fd);throw string("临时凭证文件的类型、属主或权限不正确");}
    string value;char buffer[4096];ssize_t n;
    while((n=read(fd,buffer,sizeof(buffer)))>0)value.append(buffer,n);
    close(fd);if(n<0)throw string("读取指定文件失败");return value;
}
static string field(jvalue &v,const char *name) {
    string s=v[name].as_string();if(s.empty())throw string("缺少参数：")+name;return s;
}
static jvalue inspectP12(const string &path,const string &password) {
    const string data=readFile(path);const unsigned char *pointer=reinterpret_cast<const unsigned char *>(data.data());
    std::unique_ptr<PKCS12,decltype(&PKCS12_free)> p12(d2i_PKCS12(nullptr,&pointer,data.size()),PKCS12_free);
    if(!p12)throw string("指定文件不是有效 P12 / PFX");
    EVP_PKEY *rawKey=nullptr;X509 *rawCert=nullptr;STACK_OF(X509) *chain=nullptr;
    if(PKCS12_parse(p12.get(),password.c_str(),&rawKey,&rawCert,&chain)!=1)throw string("P12 密码不正确或文件无法解析");
    std::unique_ptr<EVP_PKEY,decltype(&EVP_PKEY_free)> key(rawKey,EVP_PKEY_free);
    std::unique_ptr<X509,decltype(&X509_free)> cert(rawCert,X509_free);
    if(chain)sk_X509_pop_free(chain,X509_free);
    if(!key||!cert||X509_check_private_key(cert.get(),key.get())!=1)throw string("P12 缺少匹配的证书与私钥");
    if(X509_cmp_current_time(X509_get0_notBefore(cert.get()))>=0)throw string("P12 证书尚未生效");
    if(X509_cmp_current_time(X509_get0_notAfter(cert.get()))<=0)throw string("P12 证书已过期");
    // Actually use the file's private key and verify the signature with its public certificate.
    const unsigned char probe[]="UniPack file credential probe";
    std::unique_ptr<EVP_MD_CTX,decltype(&EVP_MD_CTX_free)> ctx(EVP_MD_CTX_new(),EVP_MD_CTX_free);
    size_t count=0;
    if(!ctx||EVP_DigestSignInit(ctx.get(),nullptr,EVP_sha256(),nullptr,key.get())!=1||EVP_DigestSign(ctx.get(),nullptr,&count,probe,sizeof(probe))!=1)throw string("指定 P12 的私钥无法签名");
    std::vector<unsigned char> signature(count);
    if(EVP_DigestSign(ctx.get(),signature.data(),&count,probe,sizeof(probe))!=1)throw string("指定 P12 私钥签名失败");
    std::unique_ptr<EVP_PKEY,decltype(&EVP_PKEY_free)> publicKey(X509_get_pubkey(cert.get()),EVP_PKEY_free);
    EVP_MD_CTX_reset(ctx.get());
    if(!publicKey||EVP_DigestVerifyInit(ctx.get(),nullptr,EVP_sha256(),nullptr,publicKey.get())!=1||EVP_DigestVerify(ctx.get(),signature.data(),count,probe,sizeof(probe))!=1)throw string("指定 P12 的私钥与证书验证不匹配");
    unsigned char digest[EVP_MAX_MD_SIZE];unsigned int size=0;
    if(X509_digest(cert.get(),EVP_sha1(),digest,&size)!=1)throw string("无法识别 P12 证书");
    static const char hex[]="0123456789ABCDEF";string identity;
    for(unsigned int i=0;i<size;++i){identity+=hex[digest[i]>>4];identity+=hex[digest[i]&15];}
    char commonName[1024]={0};X509_NAME_get_text_by_NID(X509_get_subject_name(cert.get()),NID_commonName,commonName,sizeof(commonName));
    jvalue result;result["identity"]=identity;result["name"]=string(commonName);result["privateKeyVerified"]=true;return result;
}
int main(int argc,char **argv) {
    try {
        if(argc!=3)throw string("用法：unipack-file-signer inspect|sign request.json");
        const string mode=argv[1];if(mode!="inspect"&&mode!="sign")throw string("不支持的操作");
        jvalue request;if(!request.read(readFile(argv[2])))throw string("请求 JSON 无效");
        string password=readFile(field(request,"passwordFile"),true);
        if(password.find('\0')!=string::npos)throw string("密码不能包含 NUL 字符");
        OSSL_PROVIDER_load(nullptr,"default");OSSL_PROVIDER_load(nullptr,"legacy");
        const string p12=field(request,"p12");jvalue identity=inspectP12(p12,password);
        if(mode=="inspect") {std::fill(password.begin(),password.end(),0);std::cout<<identity.write()<<std::endl;return 0;}
        ZSignAsset asset;
        const bool initialized=asset.Init("",p12,field(request,"profile"),field(request,"entitlements"),password,false,true,false);
        std::fill(password.begin(),password.end(),0);
        if(!initialized)throw string("指定 P12 与描述文件无法创建签名");
        ZBundle bundle;
        // Force all nested code to be signed. No cache, injection, removals or installs.
        if(!bundle.SignFolder(&asset,field(request,"app"),"","","",{}, {},true,false,false,false))throw string("应用或嵌入动态库文件签名失败");
        return 0;
    } catch(const string &error) {std::cerr<<error<<std::endl;return 1;}
      catch(...) {std::cerr<<"文件签名器无法完成操作"<<std::endl;return 1;}
}
