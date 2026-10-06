import AppKit
import SceneKit

extension RewardAssetDefinition {
    var architectureStyle: Int { (sequence / 10 + (poolID.contains("future") ? 5 : poolID.contains("royal") ? 2 : 0)) % 6 }
    var architectureUse: Int { (sequence - 1) % 10 }
    var architecturalName: String {
        let english = AppLocalization.language == .english
        let styles = english ? ["Chinese", "European", "Egyptian", "Middle Eastern", "Japanese", "Futuristic"] : ["中式", "西式", "埃及", "中东", "日式", "未来科技"]
        let uses = english ? ["Restaurant", "Cinema", "Library", "Hotel", "Castle", "Amusement park", "Market", "Museum", "Residence", "Observatory"] : ["餐厅", "电影院", "图书馆", "酒店", "城堡", "游乐园", "市集", "博物馆", "住宅", "天文台"]
        let decor = english ? ["Garden bench", "Lantern gateway", "Tiered fountain", "Flower cart", "Clock tower", "Sculpture garden", "Bamboo garden", "Torii", "Obelisk", "Palm oasis", "Street lights", "Solar station"] : ["花园长椅", "灯笼牌坊", "叠水喷泉", "鲜花推车", "纪念钟塔", "雕塑花园", "竹影庭院", "朱红鸟居", "方尖碑", "棕榈绿洲", "双臂街灯", "太阳能驿站"]
        return kind == .building ? "\(styles[architectureStyle])·\(uses[architectureUse])" : decor[(sequence - 1) % 12]
    }
}

enum RewardArchitecture {
    private static let cache = NSCache<NSString, SCNNode>()
    private static var materials: [String: SCNMaterial] = [:]
    static func model(_ asset: RewardAssetDefinition) -> SCNNode {
        cache.countLimit = 128
        if let node = cache.object(forKey: asset.id as NSString) { return node.clone() }
        let node = ArchitectureBuilder(asset).build()
        cache.setObject(node, forKey: asset.id as NSString)
        return node.clone()
    }
    static func material(_ hex: Int, _ pattern: String = "plain") -> SCNMaterial {
        let key = "\(hex)-\(pattern)"
        if let value = materials[key] { return value }
        let color = NSColor(calibratedRed: CGFloat((hex >> 16) & 255)/255, green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
        let m = SCNMaterial(); m.lightingModel = .physicallyBased
        m.diffuse.contents = color; m.roughness.contents = pattern == "glass" ? 0.24 : 0.82
        m.metalness.contents = pattern == "metal" ? 0.6 : 0.02
        if ["brick", "stone", "wood"].contains(pattern) {
            let image = NSImage(size: NSSize(width: 128, height: 128)); image.lockFocus()
            color.setFill(); NSRect(x: 0, y: 0, width: 128, height: 128).fill()
            color.blended(withFraction: 0.22, of: .black)!.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.5
            for y in stride(from: 0, through: 128, by: 16) {
                path.move(to: NSPoint(x: 0, y: y)); path.line(to: NSPoint(x: 128, y: y))
                if pattern != "wood" { for x in stride(from: (y/16%2)*16, through: 128, by: 32) { path.move(to: NSPoint(x:x,y:y)); path.line(to:NSPoint(x:x,y:y+16)) } }
            }
            path.stroke(); image.unlockFocus(); m.diffuse.contents = image
        }
        materials[key] = m; return m
    }
}

private final class ArchitectureBuilder {
    let a: RewardAssetDefinition
    let root = SCNNode()
    let style: Int, use: Int, tier: Int, wall: Int, roof: Int, trim: Int
    init(_ asset: RewardAssetDefinition) {
        a = asset; style = asset.architectureStyle; use = asset.architectureUse
        tier = RewardRarity.allCases.firstIndex(of: asset.rarity) ?? 0
        wall = [0xeee1c9,0xc68a69,0xe0bd79,0xead6ab,0xf1e6d1,0x426b82][style]
        roof = [0x344d49,0x4e5b72,0xc39851,0x159caa,0x3c444c,0x23394f][style]
        trim = [0x973d2c,0xf3dbb0,0x287f94,0x346a9a,0x604231,0x58dadd][style]
    }
    @discardableResult func node(_ g: SCNGeometry, _ x: Double, _ y: Double, _ z: Double, _ c: Int, _ p: String = "plain") -> SCNNode {
        let n = SCNNode(geometry:g); n.position = SCNVector3(x,y,z)
        g.materials = [RewardArchitecture.material(c,p)]; root.addChildNode(n); return n
    }
    @discardableResult func box(_ w: Double, _ h: Double, _ d: Double, _ x: Double, _ y: Double, _ z: Double, _ c: Int, _ p: String = "plain") -> SCNNode {
        node(SCNBox(width:w,height:h,length:d,chamferRadius:min(0.009,h/5)),x,y,z,c,p)
    }
    @discardableResult func cyl(_ r: Double, _ h: Double, _ x: Double, _ y: Double, _ z: Double, _ c: Int) -> SCNNode {
        let g = SCNCylinder(radius:r,height:h); g.radialSegmentCount = 12; return node(g,x,y,z,c)
    }
    @discardableResult func ball(_ r: Double, _ x: Double, _ y: Double, _ z: Double, _ c: Int) -> SCNNode {
        let g = SCNSphere(radius:r); g.segmentCount = 12; return node(g,x,y,z,c)
    }
    func beam(_ p: SCNVector3, _ q: SCNVector3, _ r: Double, _ color: Int) {
        let dx = Double(q.x-p.x), dy = Double(q.y-p.y), dz = Double(q.z-p.z)
        let n = cyl(r,sqrt(dx*dx+dy*dy+dz*dz),Double(p.x+q.x)/2,Double(p.y+q.y)/2,Double(p.z+q.z)/2,color)
        n.look(at:q,up:SCNVector3(0,0,1),localFront:SCNVector3(0,1,0))
    }
    func sign(_ text: String, _ y: Double, _ z: Double) {
        box(0.70,0.13,0.035,0,y,z,trim)
        let g = SCNText(string:text,extrusionDepth:0.001); g.font = NSFont.boldSystemFont(ofSize:10); g.flatness = 0.5
        let n = node(g,0,y-0.034,z+0.025,0xffedc1); let b = g.boundingBox
        let s = min(0.007,0.62/Double(max(1,b.max.x-b.min.x)))
        n.scale = SCNVector3(s,s,s); n.position.x = CGFloat(-Double(b.max.x+b.min.x)*s/2)
    }
    func pitched(_ w: Double, _ d: Double, _ y: Double, x: Double = 0, z: Double = 0) {
        var vertices: [SCNVector3] = []; var indices: [Int32] = []
        let curved = style == 0
        for side in [-1.0,1.0] {
            let start = Int32(vertices.count)
            for i in 0...6 { let t = Double(i)/6; let h = y+0.25*(1-t)+(curved ? 0.11*pow(t,5) : 0)
                for zz in [-d/2,d/2] { vertices.append(SCNVector3(x+side*t*w/2,h,z+zz)) }
            }
            for i in 0..<6 { let k = start+Int32(i*2); indices += [k,k+1,k+2,k+1,k+3,k+2] }
        }
        let g = SCNGeometry(sources:[SCNGeometrySource(vertices:vertices)],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let m = RewardArchitecture.material(roof).copy() as! SCNMaterial; m.isDoubleSided = true; g.materials = [m]
        root.addChildNode(SCNNode(geometry:g))
        box(0.035,0.035,d+0.04,x,y+0.26,z,trim)
        // Raised tile ribs follow each roof slope and the curled eaves.
        for zz in stride(from:-d/2,through:d/2,by:0.085) { for side in [-1.0,1.0] { for i in 0..<4 {
            let t = Double(i)/4, u = Double(i+1)/4
            beam(SCNVector3(x+side*t*w/2,y+0.26*(1-t)+(curved ? 0.11*pow(t,5):0)+0.015,z+zz),SCNVector3(x+side*u*w/2,y+0.26*(1-u)+(curved ? 0.11*pow(u,5):0)+0.015,z+zz),0.008,roof)
        } } }
    }
    func window(_ x: Double, _ y: Double, _ z: Double, side: Bool = false) {
        let f = box(0.15,0.19,0.028,x,y,z,trim)
        let p = box(0.118,0.152,0.031,x,y,z+(side ? 0:0.017),0x97becb,"glass")
        if side { f.eulerAngles.y = .pi/2; p.eulerAngles.y = .pi/2; p.position.x += 0.017 }
        else { box(0.012,0.15,0.039,x,y,z+0.02,trim); box(0.12,0.012,0.039,x,y,z+0.02,trim) }
    }
    func building(_ w: Double, _ d: Double, _ h: Double) {
        box(w,h,d,0,h/2+0.09,0,wall,style == 5 ? "glass":style == 1 ? "brick":"stone")
        box(w+0.025,0.06,d+0.025,0,0.12,0,trim)
        for y in stride(from:0.42,to:h,by:0.28) { for x in [-w*0.32,w*0.32] { window(x,y,d/2+0.012) }; for z in [-d*0.28,d*0.28] { window(w/2+0.012,y,z,side:true) } }
        box(0.18,0.29,0.035,0,0.26,d/2+0.02,0x443427,"wood"); ball(0.012,0.05,0.26,d/2+0.048,0xd5ad58)
        for i in 0..<3 { box(0.32+Double(i)*0.07,0.028,0.07,0,0.09-Double(i)*0.02,d/2+0.07+Double(i)*0.07,0xc5bba7) }
        switch style {
        case 0,4:
            pitched(w+0.19,d+0.16,h+0.09)
            for x in [-w/2+0.04,w/2-0.04] { cyl(0.025,h,x,h/2+0.1,d/2+0.03,trim) }
            for y in stride(from:0.30,to:h,by:0.25) { box(w,0.025,0.04,0,y,d/2+0.04,trim) }
            if style == 4 { for x in stride(from:-w/2+0.06,through:w/2-0.06,by:0.09) { box(0.017,0.25,0.045,x,0.55,d/2+0.05,trim) } }
            else { for x in [-w*0.39,w*0.39] { cyl(0.048,0.10,x,0.56,d/2+0.10,0xd95837); box(0.008,0.06,0.008,x,0.65,d/2+0.10,trim) } }
        case 1:
            pitched(w+0.1,d+0.1,h+0.09); box(0.11,0.27,0.12,w*0.28,h+0.31,-d*0.22,wall,"brick")
            for y in stride(from:0.35,to:h,by:0.28) { box(w+0.045,0.03,d+0.045,0,y,0,trim) }
        case 2:
            box(w+0.08,0.10,d+0.08,0,h+0.12,0,roof,"stone")
            for x in [-w*0.40,w*0.40] { cyl(0.046,h,x,h/2+0.10,d/2+0.07,wall); cyl(0.075,0.08,x,h+0.06,d/2+0.07,trim) }
            node(SCNPyramid(width:w*0.7,height:0.37,length:d*0.7),0,h+0.17,0,roof,"stone")
            for x in stride(from:-w*0.4,through:w*0.4,by:0.1) { box(0.035,0.035,0.025,x,h+0.12,d/2+0.05,trim) }
        case 3:
            box(w+0.06,0.06,d+0.06,0,h+0.11,0,trim)
            cyl(min(w,d)*0.3,0.12,0,h+0.18,0,wall)
            let dome = ball(min(w,d)*0.34,0,h+0.26,0,roof); dome.scale.y = 0.75
            cyl(0.013,0.13,0,h+min(w,d)*0.25+0.30,0,0xd7b16c)
            for x in [-w*0.43,w*0.43] { cyl(0.038,0.26,x,h+0.23,-d*0.4,trim) }
        default:
            for x in stride(from:-w/2,through:w/2,by:0.13) { box(0.013,h,0.02,x,h/2+0.09,d/2+0.025,0xbed0d0,"metal") }
            for y in stride(from:0.25,to:h+0.1,by:0.18) { box(w+0.025,0.018,d+0.025,0,y,0,trim,"metal") }
            box(w+0.07,0.04,d+0.07,0,h+0.11,0,trim,"metal"); cyl(0.012,0.32,0,h+0.29,0,trim)
        }
    }
    func build() -> SCNNode {
        let plinth = box(1.24,0.045,1.25,0,0.0225,0,0xb7b2a0,"stone")
        if a.kind == .decoration { decoration() }
        else {
            // Shared storey height across rarities and finishes; hotels and
            // futuristic residences add floors, not a random whole-model scale.
            let h = 0.78
            switch use {
            case 4: castle(h)
            case 5: amusement()
            case 6: market()
            default:
                let height = use == 3 ? h+0.5 : style == 5 && use == 8 ? h+0.9 : h
                building(use == 7 ? 1.0:0.85,0.72,height)
                switch use {
                case 0:
                    for i in 0..<8 { let n = box(0.102,0.03,0.25,-0.357+Double(i)*0.102,0.53,0.49,i%2 == 0 ? trim:0xffeaca); n.eulerAngles.x = 0.2 }
                    sign("BISTRO",0.70,0.39); cyl(0.09,0.024,-0.40,0.22,0.57,0x936739); cyl(0.012,0.16,-0.40,0.13,0.57,trim)
                case 1:
                    box(0.98,0.07,0.24,0,0.54,0.48,trim); sign("CINEMA",0.75,0.39)
                    for x in stride(from:-0.43,through:0.43,by:0.08) { ball(0.018,x,0.54,0.605,0xffd580) }
                    for x in [-0.3,0.3] { box(0.14,0.21,0.02,x,0.30,0.39,0xd9a353) }
                case 2,7:
                    sign(use == 2 ? "LIBRARY":"MUSEUM",0.70,0.39)
                    for x in [-0.36,-0.12,0.12,0.36] { cyl(0.025,0.43,x,0.32,0.48,trim) }
                case 3:
                    sign("HOTEL",height-0.10,0.39)
                    for y in stride(from:0.62,to:height-0.15,by:0.29) { box(0.7,0.025,0.15,0,y,0.43,trim); for x in [-0.32,0.32] { box(0.02,0.08,0.15,x,y+0.04,0.43,trim) } }
                case 9:
                    cyl(0.28,0.10,0,h+0.37,0,trim); let dome = ball(0.27,0,h+0.48,0,0xc3d1d4); dome.scale.y = 0.75
                    beam(SCNVector3(0,h+0.48,0),SCNVector3(0.3,h+0.79,0.1),0.06,roof)
                default: break
                }
            }
            for x in [-0.52,0.52] { box(0.12,0.09,0.12,x,0.095,-0.48,trim); ball(0.085,x,0.20,-0.48,0x5e8154) }
        }
        let b = root.boundingBox
        let s = min(Double(a.footprint.width)*0.91/Double(b.max.x-b.min.x),Double(a.footprint.depth)*0.91/Double(b.max.z-b.min.z))
        // Extend only paving into rectangular lots, without stretching doors,
        // windows or stalls. The model itself always keeps uniform XYZ scale.
        if a.kind == .building {
            let centerX = (b.max.x+b.min.x)/2, centerZ = (b.max.z+b.min.z)/2
            for child in root.childNodes {
                child.position.x -= centerX
                child.position.z -= centerZ
            }
            plinth.removeFromParentNode()
            box(Double(a.footprint.width)*0.91/s,0.045,Double(a.footprint.depth)*0.91/s,0,0.0225,0,0xb7b2a0,"stone")
        }
        root.scale = SCNVector3(s,s,s); return root
    }
    func castle(_ h: Double) {
        building(0.7,0.62,h+0.20)
        for x in [-0.46,0.46] { for z in [-0.43,0.43] {
            cyl(0.12,h+0.12,x,(h+0.12)/2+0.08,z,wall)
            if style == 0 || style == 4 { pitched(0.33,0.33,h+0.20,x:x,z:z) }
            else if style == 3 { ball(0.14,x,h+0.24,z,roof) }
            else { node(SCNCone(topRadius:0,bottomRadius:0.16,height:0.32),x,h+0.35,z,roof) }
            window(x,h*0.65,z+0.125)
        } }
        box(1.0,0.31,0.08,0,0.26,0.44,wall,"stone")
        for x in stride(from:-0.45,through:0.45,by:0.15) { box(0.075,0.10,0.12,x,0.47,0.44,wall) }
        box(0.19,0.27,0.028,0,0.23,0.49,0x44362b,"wood")
    }
    func amusement() {
        let r = 0.44, y = 0.65
        let g = SCNTorus(ringRadius:r,pipeRadius:0.022); g.ringSegmentCount = 32; g.pipeSegmentCount = 6
        let wheel = node(g,0,y,-0.08,trim); wheel.eulerAngles.x = .pi/2
        for x in [-0.24,0.24] { beam(SCNVector3(x,0.07,0.10),SCNVector3(0,y,-0.08),0.024,roof) }
        for i in 0..<10 { let angle = Double(i)*Double.pi/5, x = cos(angle)*r, yy = y+sin(angle)*r
            beam(SCNVector3(0,y,-0.08),SCNVector3(x,yy,-0.08),0.009,trim)
            box(0.10,0.09,0.09,x,yy-0.04,-0.08,[trim,0xe8b865,0x78aaa5][i%3]); box(0.11,0.015,0.10,x,yy+0.02,-0.08,roof)
        }
        cyl(0.19,0.06,0.34,0.12,0.4,trim); node(SCNCone(topRadius:0,bottomRadius:0.22,height:0.23),0.34,0.45,0.4,roof)
        for i in 0..<6 { let t = Double(i)*Double.pi/3; cyl(0.008,0.24,0.34+cos(t)*0.14,0.27,0.4+sin(t)*0.14,0xdfbe69) }
        sign("FUN PARK",0.23,0.58)
    }
    func market() {
        for x in [-0.31,0.31] { for z in [-0.29,0.29] {
            box(0.42,0.17,0.33,x,0.17,z,wall,"wood")
            for dx in [-0.18,0.18] { cyl(0.015,0.39,x+dx,0.30,z-0.12,trim) }
            for i in 0..<5 { box(0.085,0.03,0.38,x-0.17+Double(i)*0.085,0.51,z,i%2 == 0 ? trim:0xf1d9aa) }
            for i in 0..<4 { ball(0.034,x-0.12+Double(i)*0.08,0.29,z+0.05,[0xcd6542,0xd8ad42,0x75a35e][i%3]) }
        } }
    }
    func decoration() {
        switch (a.sequence-1)%12 {
        case 0:
            for z in [-0.12,-0.04,0.04,0.12] { box(0.66,0.025,0.055,0,0.26,z,0x967148,"wood") }
            for y in [0.37,0.44] { box(0.66,0.05,0.035,0,y,-0.13,0x967148,"wood") }
            for x in [-0.26,0.26] { box(0.035,0.25,0.27,x,0.15,0,trim); box(0.035,0.2,0.035,x,0.35,-0.13,trim) }
        case 1,7:
            for x in [-0.28,0.28] { cyl(0.035,0.70,x,0.37,0,0xa53b29) }
            box(0.77,0.06,0.12,0,0.74,0,0xa53b29); box(0.64,0.04,0.08,0,0.60,0,0xa53b29)
            if (a.sequence-1)%12 == 1 { pitched(0.88,0.25,0.76); for x in [-0.21,0.21] { cyl(0.065,0.12,x,0.50,0,0xdc623a) } }
        case 2:
            for (r,y) in [(0.34,0.09),(0.22,0.34),(0.12,0.58)] { cyl(r,0.05,0,y,0,wall); cyl(r*0.86,0.015,0,y+0.03,0,0x65b4c7) }; cyl(0.03,0.56,0,0.33,0,trim); ball(0.05,0,0.66,0,0x9ccfdd)
        case 3:
            box(0.55,0.16,0.34,0,0.24,0,0xa87449,"wood")
            for x in [-0.22,0.22] { for z in [-0.19,0.19] { let n = cyl(0.08,0.03,x,0.12,z,trim); n.eulerAngles.x = .pi/2 } }
            for i in 0..<9 { let x = Double(i%3)*0.14-0.14,z = Double(i/3)*0.09-0.09; cyl(0.026,0.10,x,0.36,z,0x679254); ball(0.05,x,0.43,z,[0xe7a1a9,0xe6c065,0xa99aca][i%3]) }
        case 4:
            box(0.32,0.58,0.30,0,0.34,0,wall,"stone"); pitched(0.44,0.42,0.70)
            let n = cyl(0.10,0.015,0,0.56,0.16,0xffefd2); n.eulerAngles.x = .pi/2
            box(0.012,0.07,0.017,0,0.58,0.174,trim); box(0.054,0.012,0.017,0.02,0.56,0.174,trim)
        case 5:
            box(0.29,0.19,0.29,0,0.15,0,wall,"stone")
            for i in 0..<3 { let g = SCNTorus(ringRadius:0.20,pipeRadius:0.024); g.ringSegmentCount = 24; g.pipeSegmentCount = 6; let n = node(g,0,0.48,0,0xc49b52,"metal"); n.eulerAngles = SCNVector3(Double(i)*0.7,Double(i)*0.8,0.5) }
        case 6:
            for i in 0..<7 { let x = Double(i%3)*0.16-0.16,z = Double(i/3)*0.14-0.14,h = 0.45+Double(i%3)*0.10; cyl(0.018,h,x,h/2+0.07,z,0x628c40)
                for y in stride(from:0.2,to:h,by:0.16) { cyl(0.022,0.015,x,y,z,0xabc284); let n = ball(0.075,x+0.05,y+0.02,z,0x51763b); n.scale = SCNVector3(1,0.22,0.4) }
            }
        case 8:
            box(0.26,0.12,0.26,0,0.10,0,wall,"stone"); box(0.13,0.64,0.13,0,0.46,0,wall,"stone"); node(SCNPyramid(width:0.13,height:0.14,length:0.13),0,0.78,0,0xd5b46b)
            for y in stride(from:0.25,to:0.74,by:0.09) { box(0.04,0.015,0.008,0,y,0.068,trim) }
        case 9:
            cyl(0.33,0.03,0,0.055,0,0x6db4b7)
            for x in [-0.22,0.22] { cyl(0.028,0.48,x,0.29,-0.10,0x9c774a)
                for i in 0..<7 { let t = Double(i)*Double.pi*2/7; let n = ball(0.14,x+cos(t)*0.10,0.52,-0.1+sin(t)*0.10,0x548547); n.scale = SCNVector3(1,0.19,0.38); n.eulerAngles.y = -t }
            }
        case 10:
            cyl(0.026,0.75,0,0.42,0,trim); box(0.47,0.024,0.025,0,0.78,0,trim)
            for x in [-0.22,0.22] { box(0.1,0.13,0.1,x,0.70,0,0xffd88a); box(0.14,0.025,0.14,x,0.78,0,trim) }
        default:
            cyl(0.028,0.49,0,0.28,0,trim); let n = box(0.61,0.035,0.40,0,0.54,0,0x2c648a); n.eulerAngles.x = 0.26
            for x in [-0.2,0,0.2] { box(0.009,0.008,0.38,x,0.57,0,0x89bfc9) }; box(0.16,0.24,0.14,0.23,0.16,0.22,trim)
        }
    }
}
