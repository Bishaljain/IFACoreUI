Pod::Spec.new do |s|
    s.name              = 'IFACoreUI'
    s.version           = '2.0.3'
    s.summary           = 'A Cocoa Touch framework to help you develop high quality iOS apps and app extensions faster.'
    s.homepage          = 'https://github.com/marcelo-schroeder/IFACoreUI'
    s.license           = 'Apache-2.0'
    s.author            = { 'Marcelo Schroeder' => 'marcelo.schroeder@infoaccent.com' }
    s.platform          = :ios, '10.0'
    s.requires_arc      = true
    s.source            = { :git => 'https://github.com/marcelo-schroeder/IFACoreUI.git', :tag => 'v' +  s.version.to_s }
    s.source_files      = 'IFACoreUI/IFACoreUI/classes/**/*.{h,m,swift}'
    s.resource          = 'IFACoreUI/IFACoreUI/resources/**/*.*'
    s.dependency 'IFAFoundation', '~> 2.0'
    s.swift_version = '4.0'
end
