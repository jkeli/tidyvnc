/* Copyright 2026 TidyVNC contributors. Licensed under GPL-2.0-or-later. */
#include <gtest/gtest.h>
#include <viewer/core/Invocation.h>
#include <core/Configuration.h>
#include <core/ParameterArgument.h>
#include <algorithm>
#include <atomic>
#include <set>
#include <thread>

using namespace viewer;
namespace {
InvocationCapabilities all() { return {true,true,true,true}; }
void rejected(const std::vector<std::string>& args, InvocationProblem problem, size_t argument,
              InvocationCapabilities caps = all()) {
  try { (void)InvocationSyntax::parse(args,caps); FAIL() << "Invocation was accepted"; }
  catch (const InvocationError& error) {
    EXPECT_EQ(error.problem,problem); EXPECT_EQ(error.argument,argument);
    EXPECT_STREQ(error.what(),"Invalid viewer invocation");
  }
}
}
TEST(Invocation, SharedLexicalFormsAndLiteralValues) {
  for (const auto* prefix : {"","-","--"}) {
    core::ParameterArgument part;
    ASSERT_TRUE(core::splitParameterArgument(std::string(prefix)+"Shared=one=two",part));
    EXPECT_EQ(part.name,"Shared"); EXPECT_EQ(part.value,"one=two"); EXPECT_TRUE(part.hasValue);
  }
  core::ParameterArgument untouched{"before","value",true};
  EXPECT_FALSE(core::splitParameterArgument("Shared",untouched));
  EXPECT_FALSE(core::splitParameterArgument("=host",untouched));
  EXPECT_EQ(untouched.name,"before"); EXPECT_EQ(untouched.value,"value");
  const auto parsed = InvocationSyntax::parse({"-PasswordFile","~/a b/$(not-run)\\q\n", "Shared=", "-Log=x=y"},all());
  ASSERT_EQ(parsed.assignments().size(),3u);
  EXPECT_EQ(parsed.assignments()[0].name,"PasswordFile");
  EXPECT_EQ(parsed.assignments()[0].value,"~/a b/$(not-run)\\q\n");
  EXPECT_EQ(parsed.assignments()[0].category,InvocationCategory::CredentialFile);
  EXPECT_EQ(parsed.assignments()[1].value,"");
  EXPECT_EQ(parsed.assignments()[2].value,"x=y");
}
TEST(Invocation, BooleanLookaheadAndRetainedAliasDistinction) {
  for (const auto* value : {"0","1","on","off","TRUE","False","yes","NO"}) {
    const auto parsed = InvocationSyntax::parse({"--Shared",value,"host"});
    ASSERT_EQ(parsed.assignments().size(),1u);
    EXPECT_EQ(parsed.assignments()[0].value,value);
    EXPECT_EQ(parsed.assignments()[0].argument,1u); EXPECT_EQ(parsed.assignments()[0].valueArgument,2u);
    EXPECT_EQ(parsed.operand(),"host"); EXPECT_EQ(parsed.operandArgument(),3u);
  }
  auto parsed = InvocationSyntax::parse({"-Shared","host"});
  EXPECT_EQ(parsed.assignments()[0].value,"1"); EXPECT_EQ(parsed.assignments()[0].valueArgument,0u);
  EXPECT_EQ(parsed.operand(),"host");
  parsed = InvocationSyntax::parse({"-FullColour","off"});
  EXPECT_EQ(parsed.assignments()[0].name,"FullColor"); EXPECT_EQ(parsed.assignments()[0].value,"1");
  EXPECT_EQ(parsed.operand(),"off");
  parsed = InvocationSyntax::parse({"-FullColour=off"});
  EXPECT_EQ(parsed.assignments()[0].value,"off"); EXPECT_FALSE(parsed.hasOperand());
  parsed = InvocationSyntax::parse({"-Shared","","host"});
  EXPECT_EQ(parsed.assignments()[0].value,"1"); EXPECT_EQ(parsed.operand(),"host");
}
TEST(Invocation, DifferentialRetainedRegistryConsumption) {
  core::BoolParameter shared("Shared","",false), color("FullColor","",false);
  core::AliasParameter alias("FullColour",&color);
  core::StringParameter password("PasswordFile","","");
  core::AliasParameter passwd("passwd",&password);
  const std::vector<std::vector<std::string>> cases = {
    {"-Shared"},{"--shared","NO","host"},{"Shared=off","host"},
    {"-Shared","host"},{"-Shared","","host"},{"-FullColour","off"},
    {"-FullColour=off"},{"--FullColor","false"},{"-passwd","a\\q b=secret"},
    {"PasswordFile="},{"--PasswordFile","--help"}
  };
  for (const auto& input : cases) {
    shared.setParam(false); color.setParam(false); password.setParam("");
    std::vector<char*> argv;
    for (const auto& arg : input) argv.push_back(const_cast<char*>(arg.c_str()));
    const int consumed = core::Configuration::handleParamArg(argv.size(),argv.data(),0);
    const auto parsed = InvocationSyntax::parse(input);
    ASSERT_EQ(parsed.assignments().size(),1u);
    const auto& field = parsed.assignments()[0];
    EXPECT_EQ(consumed,field.valueArgument == 2 ? 2 : 1);
    auto* retained = core::Configuration::getParam(field.name.c_str()); ASSERT_NE(retained,nullptr);
    if (field.category == InvocationCategory::CredentialFile) EXPECT_EQ(retained->getValueStr(),field.value);
    else {
      bool flag; ASSERT_TRUE(core::parseBooleanValue(field.value,flag));
      EXPECT_EQ(retained->getValueStr(),flag ? "on" : "off");
    }
  }
}
TEST(Invocation, OrderedOccurrencesOwnedAndSemanticValidationDeferred) {
  std::vector<std::string> args{"host","-sHaReD=invalid","Shared=off","-LowColourLevel","999","-FullScreenAllMonitors"};
  const auto parsed = InvocationSyntax::parse(args);
  args.assign(2,"destroyed");
  ASSERT_EQ(parsed.assignments().size(),4u);
  EXPECT_EQ(parsed.assignments()[0].name,"Shared"); EXPECT_EQ(parsed.assignments()[0].value,"invalid");
  EXPECT_EQ(parsed.assignments()[1].value,"off"); EXPECT_EQ(parsed.assignments()[2].name,"LowColorLevel");
  EXPECT_EQ(parsed.assignments()[2].value,"999"); EXPECT_EQ(parsed.assignments()[2].argument,4u);
  EXPECT_EQ(parsed.assignments()[3].name,"FullScreenAllMonitors");
  // A later resolver must reject the earlier invalid value; syntax cannot erase it.
  EXPECT_EQ(parsed.operand(),"host");
}
TEST(Invocation, OperandsRemainUnclassifiedAndExact) {
  for (const auto* value : {"host:3","[::1]::5901","/tmp/socket","./connection.tidyvnc","file.tidyvnc","unknown=value","=host"}) {
    const auto parsed = InvocationSyntax::parse({"",value,"-ViewOnly"});
    EXPECT_EQ(parsed.operand(),value); EXPECT_EQ(parsed.operandArgument(),2u);
    EXPECT_EQ(parsed.assignments().size(),1u);
  }
  rejected({"private-host","another-private-host"},InvocationProblem::ExtraOperand,2);
  rejected({"--","host"},InvocationProblem::UnknownOption,1);
  rejected({"---Shared"},InvocationProblem::UnknownOption,1);
  rejected({"-"},InvocationProblem::UnknownOption,1);
}
TEST(Invocation, MissingValuesUnknownOptionsAndUnavailableCapabilities) {
  rejected({"-PasswordFile"},InvocationProblem::MissingValue,1);
  rejected({"host","--SecurityTypes"},InvocationProblem::MissingValue,2);
  rejected({"--Password=private-secret"},InvocationProblem::UnknownOption,1);
  rejected({"-Unknown","private-secret"},InvocationProblem::UnknownOption,1);
  for (const auto* name : {"Audio","X509CA","X509CRL","GnuTLSPriority","display","SetPrimary","SendPrimary","via"})
    rejected({std::string("-")+name+"=private-value"},InvocationProblem::Unavailable,1,{});
  const auto parsed = InvocationSyntax::parse({"-via","gateway","-listen","5501"},all());
  ASSERT_EQ(parsed.assignments().size(),2u);
  EXPECT_EQ(parsed.assignments()[0].category,InvocationCategory::Tunnel);
  EXPECT_EQ(parsed.assignments()[1].category,InvocationCategory::Listen);
  EXPECT_EQ(parsed.operand(),"5501"); // Cross-field incompatibility is a resolver check.
}
TEST(Invocation, HelpAndVersionRetainPrecedingOptionsForValidation) {
  for (const auto* flag : {"-h","--help","-v","--version"}) {
    const auto parsed = InvocationSyntax::parse({"-PasswordFile=private","private-host",flag,"--unknown"});
    EXPECT_EQ(parsed.action(),std::string(flag) == "-h" || std::string(flag) == "--help" ? InvocationAction::Help : InvocationAction::Version);
    ASSERT_EQ(parsed.assignments().size(),1u); EXPECT_EQ(parsed.assignments()[0].value,"private");
    EXPECT_FALSE(parsed.hasOperand()); EXPECT_EQ(parsed.operandArgument(),0u);
  }
  rejected({"--unknown","--help"},InvocationProblem::UnknownOption,1);
  const auto priorInvalid = InvocationSyntax::parse({"-Shared=invalid","--help"});
  EXPECT_EQ(priorInvalid.assignments()[0].value,"invalid");
  const auto value = InvocationSyntax::parse({"-PasswordFile","--help"});
  EXPECT_EQ(value.action(),InvocationAction::Launch); EXPECT_EQ(value.assignments()[0].value,"--help");
  rejected({"--HELP"},InvocationProblem::UnknownOption,1);
}
TEST(Invocation, ArgumentAndAggregateBoundsAndNulls) {
  EXPECT_FALSE(InvocationSyntax::parse(std::vector<std::string>(InvocationSyntax::maximumArguments,"")).hasOperand());
  rejected(std::vector<std::string>(InvocationSyntax::maximumArguments+1,""),InvocationProblem::TooManyArguments,0);
  std::string large(InvocationSyntax::maximumArgumentBytes,'x');
  EXPECT_EQ(InvocationSyntax::parse({large}).operand(),large);
  rejected({large+"x"},InvocationProblem::TooLarge,1);
  std::vector<std::string> limit(16,"Log="+std::string(InvocationSyntax::maximumArgumentBytes-4,'x'));
  EXPECT_EQ(InvocationSyntax::parse(limit).assignments().size(),16u);
  limit.push_back("x"); rejected(limit,InvocationProblem::TooLarge,17);
  rejected({std::string("private\0secret",14)},InvocationProblem::NullByte,1);
  rejected({"--help",std::string("x\0",2)},InvocationProblem::NullByte,2);
}
TEST(Invocation, CatalogIsUniqueAndEncodingAliasesUseSharedSchema) {
  std::set<std::string> seen;
  for (const auto& option : invocationOptions(all())) {
    for (auto name : {option.name,option.alias}) {
      if (name.empty()) continue;
      std::transform(name.begin(),name.end(),name.begin(),[](unsigned char c) { return c >= 'A' && c <= 'Z' ? c+32 : c; });
      EXPECT_TRUE(seen.insert(name).second);
    }
    const auto parsed = InvocationSyntax::parse({"-"+option.name+"=value"},all());
    ASSERT_EQ(parsed.assignments().size(),1u);
    EXPECT_EQ(parsed.assignments()[0].name,option.name);
    EXPECT_EQ(parsed.assignments()[0].category,option.category);
  }
  EXPECT_TRUE(seen.count("passwd")); EXPECT_TRUE(seen.count("fullcolour")); EXPECT_TRUE(seen.count("lowcolourlevel"));
  EXPECT_FALSE(seen.count("password")); EXPECT_FALSE(seen.count("servername"));
  std::set<std::string> compiled;
  for (const auto& option : invocationOptions(InvocationCapabilities::compiled())) if (option.available) {
    compiled.insert(option.name); if (!option.alias.empty()) compiled.insert(option.alias);
  }
  std::string names;
  for (const auto& name : compiled) { if (!names.empty()) names += ','; names += name; }
  RecordProperty("available_options",names);
}
TEST(Invocation, ParsingIsConcurrentAndDoesNotMutateRetainedState) {
  core::BoolParameter shared("Shared","",false);
  std::atomic<unsigned> failures{0}; std::vector<std::thread> threads;
  for (unsigned t = 0; t < 8; ++t) threads.emplace_back([&] {
    for (unsigned i = 0; i < 100; ++i) {
      const auto value = InvocationSyntax::parse({"-Shared=on","host","-UseIPv6=off"});
      if (value.assignments().size() != 2 || value.operand() != "host") ++failures;
    }
  });
  for (auto& thread : threads) thread.join();
  EXPECT_EQ(failures,0u); EXPECT_FALSE(static_cast<bool>(shared));
}
TEST(Invocation, ValuesAreCanonicalWithoutChangingSyntaxOrLiteralPaths) {
  const auto syntax = InvocationSyntax::parse({"-Shared=YES","-FullColour=off","-QualityLevel=0x3",
    "-ScalingFactor=125%","-ShortcutModifiers=Cmd,Ctrl,Option,Win","-PointerEventInterval=010",
    "-MaxCutText=","-UseIPv6=FALSE","-passwd="+std::string(500,'x')+"\\q"});
  const auto value = syntax.validatingValues();
  const std::vector<std::string> expected{"on","off","3","125","Ctrl,Alt,Super","8","0","off",std::string(500,'x')+"\\q"};
  ASSERT_EQ(value.assignments().size(),expected.size());
  for (size_t i = 0; i < expected.size(); ++i) {
    EXPECT_EQ(value.assignments()[i].value,expected[i]);
    EXPECT_EQ(value.assignments()[i].argument,syntax.assignments()[i].argument);
  }
  EXPECT_EQ(syntax.assignments()[0].value,"YES");
  EXPECT_EQ(syntax.assignments()[2].value,"0x3");
}
TEST(Invocation, EveryValueIncludingBeforeHelpMustValidate) {
  for (const auto* bad : {"-Shared=private","-QualityLevel=10","-CursorType=private","-PointerEventInterval=-1",
       "-MaxCutText=2147483648","-MaxCutText=999999999999999999999","-UseIPv6=private",
       "-FullScreenSelectedMonitors=0","-Log=private"}) {
    const auto syntax = InvocationSyntax::parse({"host",bad,"-Shared=off","--help"});
    try { syntax.validatingValues(); FAIL() << "Invalid value accepted"; }
    catch (const InvocationError& error) {
      EXPECT_EQ(error.problem,InvocationProblem::InvalidValue); EXPECT_EQ(error.argument,2u);
      EXPECT_EQ(std::string(error.what()).find("private"),std::string::npos);
    }
  }
  EXPECT_NO_THROW(InvocationSyntax::parse({"-Log= , *:stderr:30,,"}).validatingValues());
  // String interpretation belongs to the host adapter, not the stateless parser.
  EXPECT_NO_THROW(InvocationSyntax::parse({"-DesktopSize=host-specific","-geometry=host-specific"}).validatingValues());
}
