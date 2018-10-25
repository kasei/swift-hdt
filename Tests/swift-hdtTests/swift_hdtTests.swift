import XCTest
import SPARQLSyntax
@testable import HDT

final class HDTTests: XCTestCase {
    var filename : String!
    var p : HDTParser!
    
    static var allTests = [
        ("testHDTHeader", testHDTHeader),
        ("testHDTDictionarySequence", testHDTDictionarySequence),
        ("testHDTDictionarySections", testHDTDictionarySections),
        ("testHDTDictionaryParse", testHDTDictionaryParse),
        ("testHDTTriplesParse", testHDTTriplesParse),
        ("testHDTTriplesArrayParse", testHDTTriplesArrayParse),
        ("testHDTParse", testHDTParse),
    ]

    override func setUp() {
        self.filename = "/Users/greg/data/datasets/swdf-2012-11-28.hdt"
        self.p = HDTParser()
    }
    
    func testHDTHeader() throws {
        try p.openHDT(filename)
        
        var offset : Int64 = 0
        print("reading global control information at \(offset)")
        let (info, ciLength) = try p.readControlInformation(at: offset)
        XCTAssertEqual(ciLength, 40)
        offset += ciLength
        XCTAssertEqual(info.format, "<http://purl.org/HDT/hdt#HDTv1>")
        XCTAssertEqual(info.properties, [:])
        XCTAssertEqual(info.type, .global)
        
        XCTAssertEqual(offset, 40) // location of $HDT cookie for header block
        let (header, headerLength) = try p.readHeader(at: offset)
        XCTAssertEqual(headerLength, 1779)
        offset += headerLength
        XCTAssertEqual(header.count, 1750)
        XCTAssertTrue(header.hasPrefix("<http://data.semanticweb.org/> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://purl.org/HDT/hdt#Dataset> ."))
    }
    
    func testHDTDictionarySequence() throws {
        try p.openHDT(filename)
        
        let (blocks, _) = try p.readSequence(at: 1907, assertType: 1)
        let expected = [0, 26, 56, 87, 118, 153, 185, 217, 249, 281, 313, 345, 377, 409, 440, 472, 504, 536, 568, 600, 632, 663, 695, 727, 759, 791, 823, 855, 887, 919, 951, 983, 1013, 1044, 1075, 1106, 1137, 1168, 1199, 1230, 1261, 1363, 1588, 1812, 2023, 2147, 2270, 2440, 2581, 2708, 2835, 2961, 3099, 3230, 3400, 3551, 3701, 3836, 3959, 4080, 4202, 4324, 4445, 4568, 4691, 4812, 4933, 5054, 5175, 5296, 5420, 5542, 5663, 5785, 5905, 6027, 6160, 6284, 6407, 6529, 6654, 6778, 6901, 7025, 7148, 7270, 7393, 7530, 7752, 7945, 8070, 8197, 8331, 8461, 8606, 8734, 8863, 9002, 9134, 9264, 9394, 9525, 9654, 9815, 10034, 10184, 10341, 10533, 10716, 10887, 11062, 11243, 11423, 11564, 11732, 11870, 12022, 12175, 12347, 12489, 12622, 12822, 13008, 13191, 13374, 13568, 13779, 13978, 14119, 14269, 14407, 14623, 14789, 15004, 15196, 15372, 15599, 15744, 15880, 16083, 16269, 16456, 16646, 16850, 17056, 17250, 17389, 17538, 17696, 17837, 17915, 18022, 18153, 18233, 18316, 18399, 18481, 18564, 18646, 18727, 18808, 18889, 18970, 19050, 19131, 19226, 19318, 19410, 19499, 19590, 19680, 19775, 19857, 19943, 20156, 20368, 20586, 20798, 20888, 20984, 21174, 21374, 21453, 21535, 21621, 21705, 21787, 21869, 21979, 22074, 22170, 22269, 22366, 22461, 22560, 22778, 22971, 23126, 23290, 23485, 23567, 23648, 23732, 23814, 23896, 24008, 24104, 24199, 24297, 24393, 24489, 24640, 24903, 25148, 25342, 25489, 25685, 25851, 25980, 26107, 26243, 26378, 26505, 26632, 26773, 26908, 27043, 27191, 27330, 27462, 27605, 27739, 27872, 28066, 28271, 28457, 28602, 28731, 28877, 29036, 29184, 29343, 29502, 29645, 29800, 29945, 30093, 30254, 30394, 30544, 30725, 30936, 31084, 31243, 31382, 31516, 31649, 31784, 31939, 32080, 32217, 32345, 32473, 32601, 32749, 32889, 33038, 33168, 33297, 33427, 33556, 33686, 33816, 33948, 34076, 34203, 34332, 34526, 34700, 34838, 35126, 35381, 35523, 35696, 35841, 35956, 36070, 36206, 36494, 36703, 36861, 36992, 37123, 37254, 37385, 37516, 37646, 37777, 37908, 38039, 38170, 38301, 38458, 38541, 38665, 38799, 38923, 39038, 39169, 39277, 39461, 39568, 39676, 39785, 39893, 40001, 40109, 40216, 40323, 40448, 40555, 40661, 40767, 40874, 40981, 41089, 41196, 41299, 41409, 41517, 41625, 41733, 41843, 42068, 42298, 42442, 42551, 42658, 42765, 42873, 42982, 43143, 43305, 43384, 43463, 43542, 43621, 43700, 43778, 43953, 44062, 44149, 44246, 44337, 44428, 44519, 44610, 44702, 44793, 44884, 44975, 45066, 45157, 45261, 45353, 45445, 45538, 45632, 45797, 45989, 46178, 46307, 46456, 46619, 46710, 46833, 46967, 47058, 47159, 47253, 47346, 47439, 47532, 47626, 47719, 47824, 47918, 48010, 48105, 48197, 48293, 48413, 48520, 48613, 48705, 48799, 48892, 48986, 49129, 49263, 49405, 49573, 49734, 49883, 50024, 50175, 50307, 50428, 50550, 50671, 50793, 50916, 51038, 51159, 51281, 51403, 51524, 51647, 51767, 51890, 52011, 52132, 52252, 52373, 52494, 52614, 52734, 52855, 52975, 53095, 53216, 53338, 53458, 53578, 53698, 53819, 53939, 54059, 54180, 54301, 54422, 54544, 54664, 54815, 54931, 55021, 55114, 55205, 55297, 55387, 55478, 55567, 55656, 55746, 55835, 55924, 56069, 56199, 56337, 56486, 56609, 56733, 56860, 56985, 57111, 57236, 57361, 57517, 57657, 57798, 57927, 58054, 58194, 58324, 58462, 58593, 58722, 58818, 58957, 59101, 59265, 59427, 59534, 59636, 59776, 59925, 60065, 60205, 60354, 60483, 60613, 60742, 60883, 61016, 61148, 61279, 61412, 61544, 61676, 61808, 61940, 62072, 62205, 62337, 62468, 62601, 62733, 62876, 63008, 63140, 63274, 63407, 63538, 63669, 63803, 63932, 64065, 64195, 64326, 64475, 64614, 64754, 64894, 65034, 65174, 65314, 65454, 65595, 65735, 65875, 66014, 66154, 66294, 66434, 66574, 66714, 66854, 67003, 67132, 67308, 67490, 67615, 67759, 67850, 68007, 68107, 68215, 68319, 68411, 68506, 68599, 68692, 68784, 68875, 69038, 69142, 69297, 69379, 69472, 69612, 69762, 69863, 69966, 70063, 70175, 70325, 70517, 70643, 70770, 70896, 71034, 71155, 71285, 71402, 71520, 71643, 71758, 71874, 71989, 72111, 72240, 72360, 72481, 72601, 72722, 72843, 72964, 73085, 73215, 73332, 73450, 73567, 73685, 73802, 73919, 74037, 74154, 74272, 74417, 74558, 74694, 74831, 74967, 75104, 75281, 75431, 75571, 75724, 75914, 76021, 76118, 76209, 76442, 76636, 76798, 76899, 76987, 77074, 77160, 77262, 77350, 77438, 77525, 77613, 77740, 77868, 77973, 78082, 78191, 78299, 78409, 78518, 78626, 78736, 78845, 78954, 79063, 79173, 79282, 79391, 79500, 79610, 79719, 79828, 79938, 80047, 80156, 80265, 80374, 80483, 80592, 80701, 80810, 80919, 81028, 81136, 81245, 81354, 81463, 81572, 81680, 81789, 81899, 82008, 82118, 82227, 82337, 82446, 82555, 82664, 82773, 82883, 82992, 83101, 83210, 83320, 83429, 83537, 83646, 83755, 83864, 83973, 84084, 84193, 84303, 84412, 84521, 84630, 84739, 84848, 84956, 85065, 85174, 85283, 85392, 85502, 85611, 85720, 85829, 85937, 86047, 86156, 86265, 86374, 86483, 86592, 86702, 86811, 86919, 87028, 87137, 87246, 87355, 87463, 87572, 87681, 87790, 87900, 88009, 88119, 88228, 88336, 88445, 88554, 88663, 88772, 88881, 88990, 89099, 89208, 89317, 89427, 89536, 89644, 89753, 89862, 89971, 90080, 90189, 90297, 90406, 90515, 90624, 90733, 90842, 90951, 91061, 91170, 91279, 91388, 91497, 91606, 91714, 91823, 91932, 92041, 92150, 92259, 92368, 92476, 92586, 92695, 92805, 92914, 93023, 93132, 93240, 93350, 93459, 93568, 93677, 93786, 93895, 94004, 94113, 94222, 94330, 94439, 94548, 94657, 94765, 94911, 95036, 95141, 95245, 95447, 95615, 95728, 95850, 95978, 96082, 96185, 96288, 96553, 96678, 96787, 96891, 97103, 97211, 97324, 97482, 97670, 97794, 97902, 98010, 98210, 98320, 98428, 98536, 98732, 98878, 99008, 99133, 99258, 99382, 99506, 99630, 99755, 99880, 100020, 100156, 100292, 100430, 100539, 100623, 100706, 100791, 100892, 101044, 101180, 101319, 101455, 101594, 101728, 101883, 102030, 102179, 102315, 102403, 102492, 102582, 102670, 102757, 102846, 102931, 103015, 103103, 103191, 103278, 103366, 103453, 103603, 103787, 103948, 104088, 104172, 104256, 104339, 104422, 104504, 104586, 104669, 104753, 104839, 104923, 105005, 105088, 105198, 105321, 105436, 105542, 105661, 105790, 105927, 106043, 106143, 106264, 106394, 106511, 106690, 106864, 107054, 107226, 107364, 107482, 107604, 107758, 107860, 107939, 108018, 108097, 108176, 108255, 108334, 108413, 108492, 108571, 108649, 108728, 108807, 108886, 108963, 109041, 109119, 109197, 109275, 109353, 109431, 109509, 109587, 109665, 109743, 109852, 109942, 110032, 110121, 110207, 110293, 110383, 110473, 110559, 110646, 110734, 110822, 110912, 111053, 111341, 111635, 111934, 112217, 112514, 112793, 113092, 113393, 113528, 113614, 113699, 113781, 113890, 114007, 114124, 114247, 114336, 114416, 114496, 114577, 114658, 114739, 114819, 114908, 114991, 115076, 115161, 115243, 115325, 115407, 115488, 115569, 115651, 115733, 115815, 115896, 115981, 116100, 116197, 116458, 116752, 117046, 117346, 117623, 117914, 118209, 118493, 118784, 119035, 119323, 119621, 119896, 120164, 120426, 120702, 120980, 121276, 121551, 121809, 122081, 122377, 122674, 122964, 123229, 123518, 123804, 124101, 124385, 124679, 124957, 125244, 125534, 125792, 126090, 126378, 126666, 126938, 127231, 127519, 127808, 128087, 128382, 128681, 128964, 129243, 129497, 129690, 129905, 130022, 130139, 130258, 130378, 130497, 130616, 130733, 130851, 130967, 131084, 131201, 131318, 131435, 131552, 131669, 131786, 131903, 132033, 132149, 132265, 132381, 132498, 132614, 132730, 132846, 132962, 133079, 133194, 133349, 133466, 133581, 133696, 133810, 133925, 134040, 134155, 134273, 134387, 134484, 134563, 134649, 134748, 134827, 134906, 134984, 135063, 135195, 135306, 135398, 135502, 135610, 135731, 135852, 135972, 136093, 136230, 136489, 136772, 137032, 137292, 137477, 137559, 137642, 137767, 137934, 138058, 138207, 138328, 138449, 138570, 138689, 138812, 138935, 139060, 139181, 139303, 139425, 139546, 139667, 139787, 139908, 140029, 140154, 140277, 140399, 140522, 140645, 140768, 140891, 141014, 141138, 141260, 141379, 141498, 141616, 141735, 141855, 141974, 142094, 142212, 142332, 142452, 142574, 142692, 142813, 142932, 143052, 143171, 143291, 143410, 143530, 143650, 143769, 143891, 144012, 144134, 144256, 144378, 144525, 144630, 144747, 144865, 144986, 145108, 145227, 145347, 145469, 145606, 145730, 145851, 145973, 146094, 146216, 146337, 146458, 146578, 146700, 146821, 146941, 147063, 147185, 147306, 147428, 147549, 147669, 147790, 147913, 148039, 148165, 148290, 148417, 148543, 148669, 148796, 148923, 149050, 149176, 149306, 149433, 149555, 149676, 149796, 149921, 150047, 150172, 150297, 150423, 150548, 150673, 150799, 150924, 151050, 151175, 151300, 151425, 151550, 151722, 151933, 152122, 152277, 152546, 152849, 153056, 153375, 153572, 153732, 153955, 154123, 154261, 154460, 154646, 154864, 155055, 155280, 155523, 155722, 155893, 156092, 156339, 156636, 156835, 157166, 157378, 157573, 157846, 158036, 158225, 158429, 158635, 158878, 159186, 159455, 159634, 159856, 160044, 160245, 160507, 160621, 161000, 161300, 161682, 162002, 162173, 162445, 162594, 162785, 163055, 163379, 163682, 163878, 164247, 164711, 165037, 165414, 165607, 165992, 166309, 166708, 167020, 167409, 167623, 167815, 168136, 168511, 168909, 169114, 169270, 169482, 169653, 169897, 170114, 170317, 170461, 170643, 170825, 171004, 171140, 171363, 171564, 171917, 172198, 172370, 172585, 172802, 173057, 173199, 173378, 173667, 173895, 174090, 174330, 174527, 174846, 175017, 175235, 175399, 175534, 175834, 176070, 176280, 176529, 176736, 176933, 177246, 177444, 177647, 177819, 178001, 178228, 178520, 178688, 178833, 179012, 179151, 179336, 179537, 179748, 179871, 179966, 180113, 180304, 180480, 180699, 180928, 181195, 181405, 181654, 181794, 181943, 182096, 182408, 182751, 183029, 183424, 183760, 184023, 184291, 184605, 185074, 185405, 185778, 186068, 186235, 186374, 186541, 186821, 187042, 187237, 187458, 187675, 187847, 188073, 188269, 188485, 188699, 188926, 189152, 189439, 189587, 189821, 190260, 190578, 190864, 191054, 191329, 191505, 191728, 191973, 192178, 192355, 192511, 192734, 192988, 193204, 193407, 193599, 193812, 194016, 194192, 194367, 194515, 194646, 194803, 195000, 195212, 195453, 195612, 195823, 195981, 196202, 196496, 196856, 197074, 197413, 197623, 197820, 197952, 198190, 198368, 198587, 198771, 198959, 199186, 199413, 199603, 199747, 200188, 200350, 200512, 200659, 200849, 201197, 201409, 201604, 201800, 202072, 202289, 202536, 202735, 203026, 203206, 203388, 203625, 203764, 204044, 204254, 204457, 204624, 204823, 205009, 205136, 205297, 205506, 205812, 206123, 206424, 206682, 206888, 207071, 207364, 207607, 207795, 208000, 208156, 208395, 208623, 208880, 209282, 209597, 209809, 209994, 210298, 210468, 210649, 210848, 211001, 211201, 211358, 211594, 211804, 211983, 212282, 212596, 212868, 213087, 213267, 213567, 213715, 213908, 214115, 214273, 214469, 214612, 214759, 214868, 214991, 215114, 215241, 215499, 215666, 215899, 216083, 216215, 216422, 216628, 216829, 217039, 217216, 217384, 217538, 217722, 217916, 218051, 218270, 218449, 218638, 218756, 218941, 219122, 219263, 219426, 219611, 219851, 219969, 220098, 220234, 220404, 220540, 220696, 220869, 221004, 221184, 221384, 221519, 221651, 221807, 221961, 222123, 222351, 222519, 222665, 222839, 222977, 223106, 223248, 223386, 223543, 223648, 223826, 224017, 224166, 224309, 224452, 224597, 224754, 224919, 225083, 225211, 225342, 225484, 225647, 225825, 225944, 226096, 226224, 226396, 226599, 226784, 226936, 227069, 227293, 227494, 227636, 227838, 228063, 228310, 228512, 228711, 229029, 229253, 229522, 229690, 229806, 229953, 230094, 230282, 230444, 230605, 230740, 230883, 231017, 231159, 231261, 231382, 231521, 231636, 231747, 231885, 232039, 232169, 232295, 232417, 232541, 232651, 232768, 232868, 233006, 233134, 233265, 233395, 233526, 233648, 233761, 233875, 233996, 234108, 234212, 234332, 234437, 234549, 234685, 234797, 234923, 235042, 235192, 235300, 235443, 235571, 235728, 235861, 235991, 236106, 236240, 236367, 236478, 236584, 236725, 236866, 237005, 237135, 237239, 237360, 237470, 237584, 237678, 237794, 237910, 238013, 238136, 238259, 238367, 238475, 238596, 238730, 238865, 238989, 239124, 239247, 239370, 239482, 239591, 239713, 239841, 239985, 240121, 240240, 240370, 240509, 240642, 240800, 240945, 241097, 241241, 241387, 241537, 241671, 241799, 241929, 242044, 242196, 242342, 242486, 242624, 242767, 242900, 243032, 243188, 243324, 243450, 243565, 243684, 243818, 243939, 244103, 244203, 244317, 244436, 244534, 244656, 244788, 244934, 245054, 245181, 245295, 245434, 245572, 245700, 245841, 245950, 246035, 246174, 246298, 246394, 246505, 246642, 246784, 246929, 247052, 247184, 247305, 247416, 247517, 247638, 247756, 247879, 248028, 248168, 248300, 248419, 248558, 248706, 248825, 248948, 249067, 249180, 249320, 249470, 249606, 249741, 249876, 249995, 250123, 250241, 250389, 250466, 250573, 250686, 250829, 250961, 251097, 251238, 251342, 251447, 251550, 251667, 251769, 251891, 252008, 252124, 252236, 252341, 252463, 252585, 252696, 252818, 252926, 253040, 253147, 253249, 253367, 253499, 253627, 253744, 253875, 253998, 254121, 254230, 254352, 254466, 254593, 254715, 254860, 254986, 255117, 255263, 255380, 255501, 255621, 255755, 255876, 255984, 256074, 256177, 256290, 256397, 256513, 256634, 256736, 256855, 256958, 257056, 257168, 257285, 257423, 257555, 257690, 257797, 257911, 258019, 258128, 258232, 258342, 258448, 258537, 258655, 258754, 258854, 258947, 259053, 259165, 259276, 259409, 259542, 259680, 259806, 259922, 260040, 260173, 260322, 260431, 260559, 260695, 260833, 260963, 261092, 261228, 261365, 261497, 261607, 261767, 261892, 262018, 262123, 262254, 262372, 262477, 262620, 262752, 262904, 263036, 263179, 263287, 263421, 263571, 263680, 263805, 263969, 264100, 264246, 264367, 264510, 264648, 264775, 264901, 265039, 265182, 265308, 265429, 265563, 265686, 265797, 265929, 266036, 266151, 266267, 266398, 266512, 266650, 266784, 266936, 267075, 267182, 267305, 267443, 267583, 267724, 267837, 267948, 268086, 268214, 268329, 268466, 268578, 268695, 268839, 268971, 269085, 269196, 269306, 269454, 269610, 269766, 269892, 270006, 270128, 270276, 270414, 270536, 270687, 270809, 270936, 271044, 271166, 271312, 271433, 271559, 271698, 271827, 271964, 272081, 272193, 272322, 272440, 272581, 272721, 272847, 272961, 273086, 273208, 273329, 273459, 273584, 273709, 273841, 273989, 274117, 274241, 274364, 274508, 274627, 274759, 274886, 275017, 275151, 275291, 275409, 275531, 275651, 275795, 275913, 276041, 276177, 276299, 276420, 276555, 276677, 276812, 276957, 277078, 277191, 277321, 277454, 277594, 277709, 277824, 277938, 278079, 278196, 278299, 278403, 278516, 278620, 278754, 278899, 279017, 279138, 279252, 279382, 279505, 279627, 279753, 279894, 280031, 280177, 280295, 280421, 280552, 280672, 280785, 280893, 281009, 281117, 281246, 281367, 281495, 281599, 281718, 281829, 281953, 282082, 282201, 282300, 282400, 282541, 282684, 282807, 282957, 283099, 283224, 283359, 283479, 283613, 283748, 283877, 284006, 284119, 284256, 284380, 284489, 284609, 284740, 284872, 285002, 285139, 285272, 285427, 285546, 285671, 285776, 285885, 286005, 286123, 286237, 286354, 286452, 286573, 286717, 286859, 286968, 287090, 287217, 287334, 287484, 287626, 287773, 287909, 288021, 288126, 288254, 288367, 288495, 288606, 288732, 288850, 288971, 289133, 289238, 289339, 289432, 289534, 289646, 289760, 289853, 289952, 290063, 290179, 290280, 290390, 290506, 290624, 290746, 290863, 290990, 291129, 291251, 291361, 291493, 291598, 291712, 291821, 291926, 292033, 292143, 292246, 292338, 292444, 292550, 292660, 292787, 292887, 292998, 293114, 293242, 293349, 293475, 293593, 293738, 293883, 294024, 294141, 294274, 294390, 294523, 294670, 294797, 294909, 295023, 295135, 295246, 295356, 295499, 295605, 295687, 295810, 295930, 296064, 296200, 296337, 296452, 296566, 296700, 296821, 296949, 297071, 297195, 297331, 297471, 297596, 297721, 297858, 297995, 298128, 298239, 298369, 298478, 298599, 298719, 298850, 298970, 299070, 299202, 299327, 299461, 299595, 299737, 299860, 300007, 300130, 300279, 300401, 300537, 300698, 300830, 300993, 301119, 301255, 301401, 301518, 301641, 301765, 301915, 302066, 302193, 302324, 302433, 302562, 302675, 302818, 302945, 303055, 303135, 303257, 303393, 303533, 303676, 303779, 303884, 303980, 304103, 304226, 304353, 304486, 304588, 304712, 304833, 304948, 305077, 305201, 305324, 305462, 305584, 305705, 305829, 305950, 306079, 306204, 306344, 306494, 306611, 306736, 306864, 306990, 307115, 307267, 307382, 307521, 307643, 307780, 307915, 308031, 308153, 308299, 308426, 308572, 308682, 308802, 308915, 309032, 309150, 309260, 309372, 309494, 309602, 309743, 309863, 309969, 310114, 310286, 310415, 310532, 310673, 310786, 310920, 311069, 311221, 311351, 311484, 311614, 311725, 311834, 311931, 312033, 312149, 312278, 312403, 312508, 312633, 312757, 312879, 312990, 313091, 313195, 313305, 313413, 313528, 313633, 313770, 313900, 314025, 314146, 314287, 314411, 314542, 314678, 314792, 314908, 315026, 315131, 315236, 315337, 315445, 315575, 315719, 315842, 315970, 316090, 316218, 316366, 316494, 316618, 316749, 316877, 317011, 317117, 317226, 317331, 317443, 317541, 317638, 317730, 317828, 317917, 318019, 318123, 318234, 318329, 318437, 318566, 318690, 318800, 318942, 319101, 319236, 319351, 319468, 319596, 319724, 319849, 319931, 320037, 320156, 320277, 320406, 320534, 320681, 320793, 320901, 321029, 321142, 321256, 321414, 321545, 321689, 321812, 321963, 322092, 322227, 322343, 322458, 322608, 322739, 322865, 323012, 323150, 323281, 323419, 323565, 323691, 323824, 323945, 324063, 324175, 324285, 324398, 324535, 324661, 324787, 324924, 325043, 325154, 325242, 325371, 325511, 325644, 325789, 325924, 326063, 326192, 326343, 326487, 326625, 326764, 326895, 326992, 327115, 327222, 327354, 327483, 327609, 327749, 327886, 328045, 328170, 328313, 328440, 328579, 328707, 328818, 328932, 329037, 329168, 329286, 329410, 329508, 329616, 329739, 329850, 329959, 330051, 330154, 330266, 330395, 330519, 330649, 330750, 330868, 331007, 331136, 331261, 331394, 331494, 331602, 331703, 331803, 331908, 332024, 332134, 332232, 332377, 332484, 332586, 332700, 332812, 332959, 333089, 333209, 333362, 333477, 333592, 333741, 333886, 334013, 334165, 334326, 334415, 334503, 334600, 334716, 334849, 334998, 335131, 335269, 335409, 335541, 335677, 335787, 335909, 336040, 336178, 336315, 336456, 336584, 336709, 336839, 336956, 337086, 337229, 337356, 337490, 337626, 337773, 337905, 338025, 338134, 338248, 338392, 338539, 338669, 338774, 338886, 338996, 339097, 339207, 339318, 339425, 339534, 339690, 339838, 339958, 340079, 340209, 340340, 340456, 340587, 340711, 340834, 340937, 341022, 341159, 341284, 341403, 341533, 341678, 341822, 341968, 342111, 342242, 342351, 342470, 342598, 342722, 342840, 342965, 343107, 343234, 343369, 343492, 343598, 343723, 343860, 343964, 344078, 344181, 344287, 344402, 344516, 344656, 344787, 344914, 345044, 345169, 345299, 345445, 345578, 345690, 345833, 345944, 346060, 346204, 346328, 346464, 346605, 346724, 346855, 346977, 347097, 347255, 347372, 347506, 347616, 347709, 347831, 347954, 348088, 348250, 348390, 348514, 348651, 348815, 348961, 349102, 349253, 349371, 349523, 349640, 349748, 349855, 349956, 350065, 350175, 350288, 350414, 350527, 350691, 350795, 350910, 351037, 351149, 351248, 351351, 351465, 351593, 351709, 351821, 351933, 352086, 352216, 352329, 352485, 352621, 352759, 352863, 352988, 353137, 353242, 353409, 353552, 353697, 353815, 353936, 354054, 354187, 354304, 354433, 354558, 354708, 354786, 354925, 355074, 355210, 355327, 355473, 355638, 355803, 355932, 356032, 356132, 356242, 356343, 356449, 356562, 356681, 356792, 356905, 357013, 357136, 357245, 357373, 357486, 357597, 357724, 357830, 357930, 358054, 358185, 358309, 358425, 358564, 358701, 358833, 358979, 359115, 359248, 359357, 359495, 359624, 359738, 359881, 360007, 360121, 360255, 360399, 360540, 360683, 360841, 360976, 361140, 361266, 361379, 361520, 361634, 361747, 361855, 361981, 362121, 362269, 362403, 362540, 362666, 362795, 362926, 363055, 363175, 363283, 363367, 363448, 363554, 363659, 363764, 363872, 364027, 364118, 364217, 364338, 364485, 364585, 364693, 364821, 364968, 365070, 365170, 365272, 365375, 365485, 365587, 365705, 365803, 365904, 365992, 366100, 366216, 366319, 366428, 366548, 366660, 366777, 366891, 366987, 367087, 367211, 367344, 367481, 367604, 367732, 367835, 367941, 368064, 368150, 368250, 368369, 368500, 368637, 368742, 368864, 369007, 369114, 369195, 369302, 369402, 369525, 369640, 369740, 369849, 369974, 370089, 370208, 370323, 370485, 370621, 370724, 370818, 370941, 371049, 371160, 371269, 371382, 371517, 371649, 371809, 371973, 372133, 372303, 372413, 372490, 372567, 372723, 372806, 372953, 373062, 373182, 373301, 373483, 373607, 373753, 373893, 374023, 374154, 374272, 374390, 374507, 374621, 374738, 374875, 375028, 375142, 375288, 375368, 375456, 375574, 375693, 375811, 375917, 376066, 376163, 376266, 376365, 376510, 376637, 376799, 376890, 377000, 377118, 377236, 377352, 377493, 377610, 377729, 377880, 377998, 378121, 378243, 378349, 378468, 378595, 378744, 378860, 378975, 379136, 379259, 379382, 379483, 379600, 379717, 379841, 379920, 380008, 380088, 380167, 380297, 380377, 380457, 380546, 380648, 380767, 380895, 381045, 381168, 381291, 381413, 381544, 381679, 381779, 381939, 382044, 382197, 382279, 382376, 382470, 382565, 382675, 382792, 382913, 383084, 383206, 383315, 383482, 383607, 383732, 383858, 383983, 384117, 384259, 384354, 384449, 384588, 384684, 384801, 384917, 385042, 385155, 385271, 385415, 385546, 385678, 385800, 385953, 386093, 386228, 386330, 386487, 386568, 386673, 386778, 386904, 387051, 387175, 387300, 387459, 387576, 387713, 387839, 387946, 388065, 388222, 388343, 388558, 388700, 388817, 388937, 389075, 389233, 389413, 389563, 389680, 389813, 389960, 390127, 390349, 390580, 390751, 390964, 391157, 391364, 391503, 391698, 391950, 392073, 392190, 392310, 392429, 392618, 392778, 392880, 393041, 393191, 393338, 393404, 393469, 393614, 393745, 393870, 393992, 394119, 394249, 394373, 394508, 394646, 394822, 394961, 395120, 395329, 395496, 395652, 395857, 396018, 396180, 396322, 396479, ]
        let got = Array(blocks)
        XCTAssertEqual(got, expected)
        if got != expected {
            let z = zip(got, expected)
            for (i, d) in z.enumerated() {
                let (g, e) = d
                if g != e {
                    print("Sequence data differes at index \(i): \(g) <=> \(e)")
                }
            }
        }
    }
    
    func testHDTDictionarySections() throws {
        let hdt = try p.parse(filename)

        var soCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })
        var pCounter = AnyIterator(sequence(first: Int64(1)) { $0 + 1 })

        print("============================== TESTING READ OF SHARED SECTION")
        let (shared, sharedLength) = try hdt.readDictionaryPartition(at: 1898, generator: soCounter)
        XCTAssertEqual(shared.count, 23128)
        XCTAssertEqual(sharedLength, 403370)
        
        print("============================== TESTING READ OF SUBJECTS SECTION")
        let (subjects, subjectsLength) = try hdt.readDictionaryPartition(at: 405268, generator: soCounter)
        XCTAssertEqual(subjects.count, 182)
        XCTAssertEqual(subjectsLength, 2917)
        
        print("============================== TESTING READ OF PREDICATES SECTION")
        let (predicates, predicatesLength) = try hdt.readDictionaryPartition(at: 408185, generator: pCounter)
        XCTAssertEqual(predicates.count, 170)
        XCTAssertEqual(predicatesLength, 2636)
        
        print("============================== TESTING READ OF OBJECTS SECTION")
        let (objects, objectsLength) = try hdt.readDictionaryPartition(at: 410821, generator: soCounter)
        XCTAssertEqual(objects.count, 53401)
        XCTAssertEqual(objectsLength, 4748727)
    }
    
    let expectedTermTests : [(Int64, LookupPosition, Term)] = [
        (8, .subject, Term(value: "b5", type: .blank)),
        (9, .subject, Term(value: "b6", type: .blank)),
        (1_000, .subject, Term(iri: "http://data.semanticweb.org/conference/eswc/2006/roles/paper-presenter-semantic-web-mining-and-personalisation-hoser")),
        (76_494, .object, Term(iri: "http://xmlns.com/foaf/0.1/Person")),
        (31_100, .object, Term(string: "Alvaro")),
        (118, .predicate, Term(iri: "http://www.w3.org/2000/01/rdf-schema#label")),
        //            29_177: Term(value: "7th International Semantic Web Conference", type: .language("en")),
        //            26_183: Term(integer: 3),
        ]

    func testHDTDictionaryParse() throws {
        let hdt = try p.parse(filename)
        
        do {
            let offset : Int64 = 1819
            let termDictionary = try hdt.readDictionary(at: offset)
            XCTAssertEqual(termDictionary.count, 76881)
            
            for (id, pos, expected) in expectedTermTests {
                guard let term = try termDictionary.term(for: id, position: pos) else {
                    XCTFail("No term found for ID \(id)")
                    return
                }
                XCTAssertEqual(term, expected)
            }
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
    
    func testHDTTriplesArrayParse() throws {
        let hdt = try p.parse(filename)

        let expectedPrefix : [Int64] = [90, 101, 111, 90, 101, 104, 111, 90, 101, 104, 105, 111, 17, 111, 90, 101]
        let (array, alength) : ([Int64], Int64) = try hdt.readArray(at: 5210938)
        
        let gotPrefix = Array(array.prefix(expectedPrefix.count))
        XCTAssertEqual(gotPrefix, expectedPrefix)
    }
    
    func testHDTTriplesParse() throws {
        let hdt = try p.parse(filename)

        let expectedPrefix : [(Int64, Int64, Int64)] = [
            (1, 90, 13304),
            (1, 101, 19384),
            (1, 111, 75817),
            (2, 90, 19470),
            (2, 101, 13049),
            (2, 104, 13831),
            (2, 111, 75817),
        ]
        let triples : AnyIterator<(Int64, Int64, Int64)> = try hdt.readTriples(at: 5159548)
        let gotPrefix = Array(triples.prefix(expectedPrefix.count))
        for (i, d) in zip(gotPrefix, expectedPrefix).enumerated() {
            let (g, e) = d
            print("got triple: \(g)")
            XCTAssertEqual(g.0, e.0)
            XCTAssertEqual(g.1, e.1)
            XCTAssertEqual(g.2, e.2)
        }
    }

    func testHDTTriples() throws {
        do {
            let triples = try p.triples(from: filename)
            guard let t = triples.next() else {
                XCTFail()
                return
            }
            print(t)
        } catch let error {
            XCTFail(String(describing: error))
        }
    }

    func testHDTParse() throws {
        do {
            let hdt = try p.parse(filename)
        } catch let error {
            XCTFail(String(describing: error))
        }
    }
}

