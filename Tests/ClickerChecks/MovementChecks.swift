import Foundation
import CoreGraphics
import ScoutClicker

@MainActor func movementChecks(_ test: (String, () -> Bool) -> Void) {
    let bounds=CGRect(x:0,y:0,width:800,height:600), start=CGPoint(x:100,y:300), end=CGPoint(x:700,y:300)
    let midpoint: (ClosedRange<Double>)->Double = { ($0.lowerBound+$0.upperBound)/2 }
    func setup(_ small: Bool, _ large: Bool, mutate: (inout ClickSettings)->Void = { _ in }) -> (ClickEngine,FakeMouse,Clock,ClickSettings) {
        let m=FakeMouse(),c=Clock();var s=ClickSettings()
        s.smallMovementEnabled=small;s.largeMovementEnabled=large;s.movementProbability=1;s.largeMovementProbability=1
        s.breaksEnabled=false;s.minInterval=100;s.maxInterval=100;s.movementRadius=10
        mutate(&s)
        return (ClickEngine(output:m,scheduler:c,random:midpoint),m,c,s)
    }
    test("Migration preserves selected mode, enabled state, frequencies and unrelated settings") {
        for mode in MovementMode.allCases { for enabled in [false,true] {
            let data=try! JSONSerialization.data(withJSONObject:["movementMode":mode.rawValue,"movementEnabled":enabled,"movementProbability":0.73,"movementRadius":19,"movementDisplayID":42,"timerEnabled":true,"timerMinutes":31,"timerSeconds":26,"finalClickEnabled":true,"finalButton":"Left click","button":"Right click","clickVariationEnabled":true,"clickVariationRadius":3,"breaksEnabled":false])
            let s=try! JSONDecoder().decode(ClickSettings.self,from:data)
            if s.smallMovementEnabled != (enabled && mode == .local) || s.largeMovementEnabled != (enabled && mode == .fullScreen) || s.movementProbability != 0.73 || s.largeMovementProbability != 0.73 || s.movementRadius != 19 || s.movementDisplayID != 42 || s.timerDuration != 1886 || !s.finalClickEnabled || s.finalButton != .left || !s.clickVariationEnabled || s.clickVariationRadius != 3 || s.breaksEnabled { return false }
        } };return true
    }
    test("Disabling movement retains both probabilities, radius and regions across persistence") {
        var s=ClickSettings();s.movementProbability=0.11;s.largeMovementProbability=0.88;s.movementRadius=17
        s.movementDisplayIdentity="test-display";s.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:2,y:3,width:100,height:200),blocked:true)])]
        s.smallMovementEnabled=false;s.largeMovementEnabled=false
        return (try! JSONDecoder().decode(ClickSettings.self,from:JSONEncoder().encode(s))) == s
    }
    for (small,large) in [(true,false),(false,true),(true,true),(false,false)] {
        test("Independent switches small=\(small), large=\(large); one click and one chain") {
            let (e,m,c,s)=setup(small,large);var phases=[String]()
            e.changed={ if let p=e.movementPhase, phases.last != p { phases.append(p) } }
            e.start(at:m.position,settings:s)
            for _ in 0..<800 { c.advance(0.01);if c.queued.filter({ !$0.1.cancelled }).count > 1 { return false } }
            let expected=(small ? ["Small outward","Small return"] : [])+(large ? ["Large outward","Large return"] : [])
            return phases == expected && m.downs.count == 1 && m.held == nil
        }
    }
    for (smallP,largeP) in [(0.4,0.6),(0.6,0.4)] {
        test("Probabilities are independent: small \(smallP), large \(largeP)") {
            let (e,m,c,s)=setup(true,true) { $0.movementProbability=smallP;$0.largeMovementProbability=largeP }
            var phases=[String]();e.changed={ if let p=e.movementPhase,phases.last != p { phases.append(p) } }
            e.start(at:m.position,settings:s);c.advance(8)
            return phases == (smallP>0.5 ? ["Small outward","Small return"] : ["Large outward","Large return"])
        }
    }
    test("Spatial curves and separately generated returns do not retrace") {
        let domain=MovementDomain(bounds:bounds)
        guard let out=CurvedMovement.plan(from:start,to:end,domain:domain,random:midpoint),let back=CurvedMovement.plan(from:end,to:start,domain:domain,random:midpoint) else { return false }
        return out.points.contains { abs($0.y-start.y)>10 } && back.points.contains { abs($0.y-start.y)>10 } && movementDistance(out.curves[0].point(0.5),back.curves[0].point(0.5))>20 && out.points.last == end && back.points.last == start
    }
    for large in [false,true] {
        test("\(large ? "Large" : "Small") begins at current pointer, with no target snap; direct varied return") {
            let (e,m,c,s)=setup(!large,large) { $0.clickVariationEnabled=true;$0.clickVariationRadius=2 }
            let anchor=m.position;e.start(at:anchor,settings:s);e.pause();m.position=CGPoint(x:250,y:250)
            let current=m.position;e.start(settings:s);c.advance(8)
            guard let first=m.events.first,let down=m.downs.first,let i=m.events.firstIndex(where:{$0.0.hasPrefix("down")}),i>=2 else { return false }
            return movementDistance(first.1,current)<5 && first.1 != anchor && down.1 != anchor && movementDistance(down.1,anchor)<=2 && m.events[i-1].1 == down.1 && m.events[i-2].1 == down.1 && e.target == anchor && m.events.filter({$0.0.hasPrefix("up")}).first?.1 == down.1
        }
        test("\(large ? "Large" : "Small") movement-only needs no target and returns to excursion start") {
            let (e,m,c,s)=setup(!large,large) { $0.regularClickingEnabled=false }
            let anchor=m.position;e.start(settings:s);c.advance(8)
            return e.status == .running && e.target == nil && m.position == anchor && m.downs.isEmpty && m.events.count>20
        }
    }
    test("Allowed union and overlapping blocked boxes give blocked priority") {
        let d=MovementDomain(bounds:bounds,allowed:[CGRect(x:50,y:50,width:400,height:400),CGRect(x:300,y:50,width:400,height:400)],blocked:[CGRect(x:350,y:200,width:20,height:50)])
        return d.contains(CGPoint(x:600,y:100)) && d.permitsSegment(CGPoint(x:100,y:100),CGPoint(x:600,y:100)) && !d.contains(CGPoint(x:355,y:220)) && !d.permitsSegment(CGPoint(x:100,y:220),CGPoint(x:600,y:220)) && !d.contains(.zero)
    }
    test("Exact segment check detects subpixel obstacle and tangent contact") {
        let d=MovementDomain(bounds:bounds,blocked:[CGRect(x:333.333,y:200,width:0.0001,height:100)])
        return !d.permitsSegment(start,end) && !d.permitsSegment(CGPoint(x:100,y:200),CGPoint(x:700,y:200))
    }
    test("Whole cubic bow is rejected even when endpoints and chord are allowed") {
        let d=MovementDomain(bounds:bounds,blocked:[CGRect(x:300,y:330,width:200,height:120)])
        let curve=MovementCurve(start,CGPoint(x:250,y:450),CGPoint(x:550,y:450),end)
        return d.permitsSegment(start,end) && !d.permitsCurve(curve)
    }
    test("Curved route goes around a narrow obstacle; dense independent trace stays outside") {
        let obstacle=CGRect(x:399.9,y:100,width:0.2,height:350), d=MovementDomain(bounds:bounds,blocked:[obstacle])
        guard let path=CurvedMovement.plan(from:start,to:end,domain:d,random:midpoint) else { return false }
        var last=start
        for p in path.points { if !d.permitsSegment(last,p) { return false };last=p }
        for curve in path.curves { for i in 0...1000 { if obstacle.contains(curve.point(Double(i)/1000)) { return false } } }
        return path.curves.count>1 && path.points.last == end
    }
    test("Disconnected allowed rectangles cannot be bridged or teleported") {
        let d=MovementDomain(bounds:bounds,allowed:[CGRect(x:0,y:0,width:300,height:600),CGRect(x:500,y:0,width:300,height:600)])
        return !d.permitsSegment(start,end) && d.route(from:start,to:end) == nil && CurvedMovement.plan(from:start,to:end,domain:d,random:midpoint) == nil
    }
    test("Solid barrier gives impossible route, while no allowed boxes means display minus blocked") {
        let d=MovementDomain(bounds:bounds,blocked:[CGRect(x:399,y:0,width:2,height:600)])
        return d.contains(start) && d.contains(end) && !d.contains(CGPoint(x:400,y:300)) && d.route(from:start,to:end) == nil
    }
    test("Profiles translate with display arrangement, reject wrong identity and logical size changes") {
        let profile=MovementRegionProfile(displayIdentity:"a",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:10,y:10,width:50,height:50),blocked:false)])
        let moved=MovementDisplay(identity:"a",bounds:bounds.offsetBy(dx:-800,dy:120))
        return profile.domain(for:moved)?.contains(CGPoint(x:-780,y:140)) == true && profile.domain(for:MovementDisplay(identity:"b",bounds:bounds)) == nil && profile.domain(for:MovementDisplay(identity:"a",bounds:CGRect(x:0,y:0,width:400,height:300))) == nil
    }
    test("Out-of-bounds or excessive saved boxes require correction") {
        let invalid=MovementRegionProfile(displayIdentity:"a",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:790,y:0,width:50,height:20),blocked:false)])
        let excessive=MovementRegionProfile(displayIdentity:"a",referenceSize:bounds.size,boxes:(0..<33).map {_ in MovementBox(rect:CGRect(x:10,y:10,width:5,height:5),blocked:true)})
        let display=MovementDisplay(identity:"a",bounds:bounds)
        return invalid.domain(for:display) == nil && excessive.domain(for:display) == nil
    }
    test("Region conflict skips large excursion without constraining regular clicks") {
        let (e,m,c,s)=setup(false,true) { $0.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:300,y:0,width:500,height:600),blocked:false)])] }
        e.start(at:m.position,settings:s);c.advance(1)
        return e.active && m.downs.count == 1 && e.movementNote?.contains("current pointer") == true
    }
    test("Return outside regions skips large movement with explicit reason") {
        let (e,m,c,s)=setup(false,true) { $0.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:300,y:0,width:500,height:600),blocked:false)])] }
        e.start(at:m.position,settings:s);e.pause();m.position=CGPoint(x:500,y:300);e.start(settings:s);c.advance(1)
        return m.downs.count == 1 && e.movementNote?.contains("return position") == true
    }
    test("Manual movement across region boundary skips excursion, keeps session and original target") {
        let (e,m,c,s)=setup(false,true) { $0.regularClickingEnabled=false;$0.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:CGRect(x:100,y:100,width:500,height:400),blocked:false)])] }
        e.start(at:m.position,settings:s);c.advance(0.2);let target=e.target;m.position=CGPoint(x:750,y:550);let n=m.events.count;c.advance(2)
        return e.active && e.target == target && m.events.count == n && e.movementNote?.contains("boundary") == true
    }
    test("Both movements cancel immediately on Pause or Stop, even with stale callbacks") {
        for stop in [false,true] {
            let (e,m,c,s)=setup(true,true);e.start(at:m.position,settings:s);c.advance(0.7)
            if stop { e.stop() } else { e.pause() };let n=m.events.count;c.advance(100,forceCancelled:true)
            if e.active || m.events.count != n || m.held != nil { return false }
        };return true
    }
    test("Large-only boxes never affect small movement or the exact final click") {
        let (e,m,c,s)=setup(true,false) {
            $0.movementRegions=[MovementRegionProfile(displayIdentity:"test-display",referenceSize:bounds.size,boxes:[MovementBox(rect:bounds,blocked:true)])]
            $0.timerEnabled=true;$0.timerMinutes=0;$0.timerSeconds=1;$0.finalClickEnabled=true;$0.finalButton = .left
        }
        let final=CGPoint(x:650,y:450);_=e.captureFinalTarget(final);e.start(at:m.position,settings:s);c.advance(1.1);e.confirmDelivery()
        return e.status == .stopped && m.events.filter({$0.0 == "move"}).count>10 && m.downs.filter({$0.0 == "down-Left click"}).map(\.1) == [final]
    }
}
