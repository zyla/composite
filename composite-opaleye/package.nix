{ mkDerivation, base, bytestring, composite-base, lens, opaleye
, postgresql-simple, product-profunctors, profunctors, stdenv
, template-haskell, text, vinyl
}:
mkDerivation {
  pname = "composite-opaleye";
  version = "0.4.1.0";
  src = ./.;
  libraryHaskellDepends = [
    base bytestring composite-base lens opaleye postgresql-simple
    product-profunctors profunctors template-haskell text vinyl
  ];
  homepage = "https://github.com/ConferHealth/composite#readme";
  description = "Opaleye SQL for Frames records";
  license = stdenv.lib.licenses.bsd3;
}
